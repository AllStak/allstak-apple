import Foundation

/// Minimal async POST seam so the ``Transport`` can be driven by a real
/// `URLSession` in production and a deterministic stub in tests, without the
/// transport ever importing test code or blocking on a real socket.
protocol HTTPPoster: Sendable {
    /// POST `body` to `url` with the given headers. Returns `(status, retryAfter)`
    /// on a completed HTTP exchange; throws on a transport/network error (no
    /// response). `retryAfter` is the raw `Retry-After` header value, if any.
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, retryAfter: String?)
}

/// Production `HTTPPoster` over an ephemeral `URLSession`. Each request carries a
/// short timeout so transport I/O never stalls the host app; failures surface as
/// thrown errors (classified as retryable network errors by the transport).
struct URLSessionPoster: HTTPPoster {
    let session: URLSession
    var timeout: TimeInterval = 10

    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, retryAfter: String?) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            // No HTTP status → treat as a transient network error.
            throw URLError(.badServerResponse)
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        return (http.statusCode, retryAfter)
    }
}

/// Reliable transport for AllStak ingest envelopes.
///
/// Replaces the SDK's prior fire-and-forget `dataTask().resume()` (which lost any
/// failed/offline POST forever). Every send goes through:
///
///   1. **Bounded retry + exponential backoff + jitter** for transient failures
///      (429 / 5xx / network), honouring a server `Retry-After` (delta-seconds or
///      HTTP-date, capped ~300s) over the computed backoff.
///   2. **Permanent-drop** on a non-retryable 4xx (the server will never accept
///      this payload) — and the persisted copy, if any, is removed.
///   3. **401 → disable the SDK**: an invalid key short-circuits all future sends.
///   4. **Persist on exhaustion**: when retries are exhausted the ALREADY-SCRUBBED
///      bytes are written to the on-disk ``EnvelopeSpool`` and replayed on the next
///      init. Session lifecycle paths (`/sessions/start` + `/end`) are best-effort
///      live-only and are never spooled.
///
/// Fully fail-open: no method ever throws into the caller, and the transport never
/// blocks the host app (sends run on a detached `Task`).
final class Transport: @unchecked Sendable {

    private let baseURL: String
    private let apiKey: String
    private let poster: HTTPPoster
    private let spool: EnvelopeSpool?
    /// Injected sleep so tests can drive backoff without real delays. Seconds.
    private let sleep: @Sendable (Double) async -> Void
    /// Injected jitter unit `[0,1)` so backoff is deterministic under test.
    private let randomUnit: @Sendable () -> Double

    private let lock = NSLock()
    /// Set once a 401 is seen — every subsequent send is a silent no-op.
    private var disabled = false

    init(baseURL: String,
         apiKey: String,
         poster: HTTPPoster,
         spool: EnvelopeSpool?,
         sleep: @escaping @Sendable (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        // Normalize trailing slash so host + path is well-formed.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.poster = poster
        self.spool = spool
        self.sleep = sleep
        self.randomUnit = randomUnit
    }

    var isDisabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return disabled
    }

    /// Synchronously flip the SDK to disabled (after a 401). Pulled out of the
    /// async delivery loop so the lock is never held across an `await`
    /// suspension point (an error under the Swift 6 language mode).
    private func markDisabled() {
        lock.lock(); disabled = true; lock.unlock()
    }

    /// Final disposition of one delivery, surfaced to the crash-flush caller so it
    /// knows whether the on-disk `.crash` file may be removed.
    enum Resolution: Equatable {
        /// 2xx accepted, permanent-4xx dropped, 401-disabled, or successfully
        /// handed to the persistent spool — in every case the source `.crash`
        /// file MAY be removed (the spool now owns any remaining retry).
        case settled
        /// Could not deliver AND could not persist (no spool / spool refused /
        /// transport off) — the caller MUST keep the source for the next launch.
        case keepSource
    }

    /// Fire-and-forget send of an already-scrubbed JSON body to `path`. Spawns a
    /// detached task so it never blocks the caller; the task runs the full
    /// retry/backoff/persist pipeline. A blank API key (transport effectively
    /// off) and a disabled SDK both short-circuit to a no-op.
    func send(path: String, body: Data) {
        guard !apiKey.isEmpty, !isDisabled else { return }
        Task.detached { [weak self] in
            await self?.deliver(path: path, body: body, persistId: nil)
        }
    }

    /// Drain the persistent spool: load every previously-failed envelope and
    /// replay it through the same pipeline. An entry is removed only after a 2xx
    /// accept or a permanent drop; a transient failure re-persists it (under the
    /// same id) for the next init. Runs detached and fail-open.
    func drainSpool() {
        guard let spool, !apiKey.isEmpty, !isDisabled else { return }
        let entries = spool.load()
        guard !entries.isEmpty else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            for entry in entries {
                if self.isDisabled { break }
                // Defensive: never replay a session lifecycle call even if one
                // leaked into the spool from an older SDK version.
                guard isPersistablePath(entry.path), let payload = entry.payload else {
                    spool.remove(id: entry.id)
                    continue
                }
                await self.deliver(path: entry.path, body: payload, persistId: entry.id)
            }
        }
    }

    /// Synchronously persist an already-scrubbed body to the spool (no send).
    /// Used by the NSException crash path and shutdown spill so events queued when
    /// the process is about to die survive to the next launch. Session paths are
    /// refused by the spool itself. Fail-open.
    @discardableResult
    func persistNow(path: String, body: Data) -> Bool {
        guard let spool else { return false }
        return spool.enqueue(path: path, payload: body)
    }

    /// Flush a crash report recorded on a PREVIOUS launch through the transport.
    /// The on-disk crash record is owned by ``CrashStore``; this method only tells
    /// the caller — via `onResolved` — whether that record may now be removed:
    ///
    ///   * ``Resolution/settled`` — the event was accepted (2xx), permanently
    ///     dropped (4xx), 401-disabled, or successfully handed to the persistent
    ///     spool (which now owns any further retry). Remove the crash record.
    ///   * ``Resolution/keepSource`` — delivery failed AND could not be persisted
    ///     (no spool / spool refused / transport off). KEEP the crash record so a
    ///     later launch retries it. Fixes the old "clear after one unacked send"
    ///     bug. Runs detached; never blocks launch.
    func flushCrash(path: String, body: Data, onResolved: @escaping @Sendable (Resolution) -> Void) {
        guard !apiKey.isEmpty, !isDisabled else { onResolved(.keepSource); return }
        Task.detached { [weak self] in
            guard let self else { onResolved(.keepSource); return }
            let resolution = await self.deliver(path: path, body: body, persistId: nil)
            onResolved(resolution)
        }
    }

    // MARK: - Delivery pipeline (async, fail-open)

    /// Run one envelope through retry/backoff and return its ``Resolution``.
    /// `persistId` is non-nil when this is a replay from the spool (so
    /// success/permanent-drop removes the stored copy and a transient failure
    /// re-persists under the SAME id rather than spawning a duplicate).
    @discardableResult
    private func deliver(path: String, body: Data, persistId: String?) async -> Resolution {
        guard !apiKey.isEmpty, !isDisabled else { return .keepSource }
        guard let url = URL(string: baseURL + path) else { return .keepSource }
        let headers = [
            "Content-Type": "application/json",
            "X-AllStak-Key": apiKey,
        ]

        var attemptIndex = 0
        while true {
            let outcome = await runAttempt(url: url, headers: headers, body: body)
            switch outcome {
            case .accepted:
                if let persistId { spool?.remove(id: persistId) }
                return .settled
            case .unauthorized:
                markDisabled()
                if let persistId { spool?.remove(id: persistId) }
                // A 401 is terminal for the SDK; the crash record can be cleared
                // (replaying it would only hit the same disabled key).
                return .settled
            case .permanent:
                if let persistId { spool?.remove(id: persistId) }
                return .settled
            case .retryable(let retryAfterSeconds):
                if attemptIndex >= RetryPolicy.maxRetries {
                    // Retries exhausted → hand to the persistent spool (skip
                    // session paths). A replay re-persists under its own id.
                    let persisted = persistOnExhaustion(path: path, body: body, persistId: persistId)
                    // If we managed to spool it (or it was already a spool replay),
                    // the source may be cleared — the spool now owns retry. If we
                    // could NOT persist, tell the caller to keep its source.
                    return (persisted || persistId != nil) ? .settled : .keepSource
                }
                let backoff = RetryPolicy.backoffSeconds(attempt: attemptIndex, randomUnit: randomUnit)
                let delay = retryAfterSeconds > 0 ? retryAfterSeconds : backoff
                await sleep(delay)
                attemptIndex += 1
                if isDisabled { return .keepSource }
            }
        }
    }

    /// One POST attempt → classified outcome. A thrown transport error is mapped
    /// to a retryable network failure (no response).
    private func runAttempt(url: URL, headers: [String: String], body: Data) async -> RetryPolicy.Outcome {
        do {
            let (status, retryAfter) = try await poster.post(url: url, headers: headers, body: body)
            return RetryPolicy.classify(status: status, retryAfter: retryAfter)
        } catch {
            return RetryPolicy.classify(status: nil, retryAfter: nil) // network error → retry
        }
    }

    /// Persist on retry exhaustion. A replay (persistId set) re-persists under the
    /// same id so it isn't duplicated; a fresh send mints a new id. Session paths
    /// are refused by the spool (best-effort live-only). Returns `true` when the
    /// body was actually written to the spool (a session path or absent spool
    /// returns `false`).
    @discardableResult
    private func persistOnExhaustion(path: String, body: Data, persistId: String?) -> Bool {
        guard let spool else { return false }
        if let persistId {
            return spool.enqueue(SpooledEnvelope(id: persistId, path: path, payload: body))
        } else {
            return spool.enqueue(path: path, payload: body)
        }
    }
}

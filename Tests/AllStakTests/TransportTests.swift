import XCTest
@testable import AllStak

/// Reliable-transport behavior: retry then persist, drain-on-init + remove-after-2xx,
/// session paths never spooled, permanent-4xx drop, 401 disables the SDK, crash
/// flush cleared only after ack, and fail-open. Uses a scripted in-memory poster
/// (no real network) and a no-op sleep so backoff never actually delays the test.
final class TransportTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-transport-test-" + UUID().uuidString)
    }

    private func body(_ s: String) -> Data { Data(s.utf8) }

    /// Scripted poster. Each call pops the next response; once the script is
    /// exhausted the last response repeats. Records every request and signals an
    /// optional expectation after a target number of calls.
    final class StubPoster: HTTPPoster, @unchecked Sendable {
        struct Response {
            let httpStatus: Int?
            let retryAfter: String?
            let throwsError: Bool
            // Factories live ON Response so `[.ok()]` leading-dot syntax resolves.
            static func ok() -> Response { Response(httpStatus: 200, retryAfter: nil, throwsError: false) }
            static func code(_ s: Int, retryAfter: String? = nil) -> Response {
                Response(httpStatus: s, retryAfter: retryAfter, throwsError: false)
            }
            static func networkError() -> Response { Response(httpStatus: nil, retryAfter: nil, throwsError: true) }
        }
        struct Request { let url: URL; let body: Data }

        private let lock = NSLock()
        private var script: [Response]
        private var index = 0
        private(set) var requests: [Request] = []

        var onCount: (count: Int, fulfill: () -> Void)?

        init(_ script: [Response]) { self.script = script }

        func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return requests.count }

        /// Record the request and pop the next scripted response under the lock,
        /// kept out of the async method so the lock is never held across an await.
        private func record(_ req: Request)
            -> (resp: Response, count: Int, target: (count: Int, fulfill: () -> Void)?) {
            lock.lock(); defer { lock.unlock() }
            requests.append(req)
            let resp = index < script.count ? script[index] : (script.last ?? Response.ok())
            if index < script.count { index += 1 }
            return (resp, requests.count, onCount)
        }

        func post(url: URL, headers: [String: String], body: Data) async throws
            -> (status: Int, retryAfter: String?) {
            let (resp, count, target) = record(Request(url: url, body: body))
            if let target, count >= target.count { target.fulfill() }
            if resp.throwsError { throw URLError(.notConnectedToInternet) }
            return (resp.httpStatus ?? 200, resp.retryAfter)
        }
    }

    /// No-op sleep so the retry loop never actually waits.
    private let noSleep: @Sendable (Double) async -> Void = { _ in }
    private let fixedJitter: @Sendable () -> Double = { 0.5 }

    private func makeTransport(poster: HTTPPoster, spool: EnvelopeSpool?,
                               apiKey: String = "k") -> Transport {
        Transport(baseURL: "https://h.test", apiKey: apiKey, poster: poster,
                  spool: spool, sleep: noSleep, randomUnit: fixedJitter)
    }

    // MARK: 2xx — sent once, nothing spooled

    func test2xxSendsOnceAndDoesNotSpool() {
        let poster = StubPoster([.ok()])
        let exp = expectation(description: "posted")
        poster.onCount = (1, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/errors", body: body("{}"))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(poster.requestCount(), 1, "a 2xx is delivered exactly once")
        XCTAssertEqual(spool.count(), 0, "an accepted event is never spooled")
    }

    // MARK: retry then persist (network errors)

    func testRetriesThenPersistsOnPersistentNetworkFailure() {
        // Every attempt is a network error: 1 initial + maxRetries attempts, then
        // the body is handed to the spool.
        let poster = StubPoster([.networkError()])
        let exp = expectation(description: "all attempts made")
        let totalAttempts = RetryPolicy.maxRetries + 1
        poster.onCount = (totalAttempts, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/errors", body: body("payload"))
        wait(for: [exp], timeout: 2)
        // Give the detached task a beat to finish persisting after the last attempt.
        let persisted = expectation(description: "persisted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { persisted.fulfill() }
        wait(for: [persisted], timeout: 2)

        XCTAssertEqual(poster.requestCount(), totalAttempts,
                       "1 initial + maxRetries attempts before persisting")
        let kept = spool.load()
        XCTAssertEqual(kept.count, 1, "the exhausted body is persisted")
        XCTAssertEqual(kept[0].payload, body("payload"), "ALREADY-SCRUBBED bytes are stored verbatim")
        XCTAssertEqual(kept[0].path, "/ingest/v1/errors")
    }

    func testRetriesThenSucceeds() {
        // Two network errors, then a 200 → delivered without persisting.
        let poster = StubPoster([.networkError(), .networkError(), .ok()])
        let exp = expectation(description: "succeeded on 3rd")
        poster.onCount = (3, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/errors", body: body("x"))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(spool.count(), 0, "a retry that eventually succeeds is not spooled")
    }

    // MARK: 429 / 5xx are retryable

    func test429RetriesThenPersists() {
        let poster = StubPoster([.code(429, retryAfter: "0")])
        let exp = expectation(description: "attempts")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/errors", body: body("rate"))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(spool.count(), 1, "exhausted 429s persist for the next launch")
    }

    // MARK: non-retryable 4xx — dropped, never spooled

    func testPermanent4xxDroppedNotSpooledNotRetried() {
        let poster = StubPoster([.code(400)])
        let exp = expectation(description: "single attempt")
        poster.onCount = (1, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/errors", body: body("bad"))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(poster.requestCount(), 1, "a permanent 4xx is not retried")
        XCTAssertEqual(spool.count(), 0, "a permanent 4xx is dropped, never persisted")
    }

    // MARK: 401 disables the SDK

    func test401DisablesTransport() {
        let poster = StubPoster([.code(401)])
        let exp = expectation(description: "single attempt")
        poster.onCount = (1, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        XCTAssertFalse(transport.isDisabled)
        transport.send(path: "/ingest/v1/errors", body: body("first"))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertTrue(transport.isDisabled, "401 disables the SDK")
        XCTAssertEqual(spool.count(), 0, "a 401 is terminal, not persisted")

        // A subsequent send is a silent no-op (no new request hits the poster).
        let before = poster.requestCount()
        transport.send(path: "/ingest/v1/errors", body: body("second"))
        let quiet = expectation(description: "no further request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(poster.requestCount(), before, "no sends after disable")
    }

    // MARK: drain-on-init + remove-after-2xx

    func testDrainSpoolReplaysAndRemovesAfter2xx() {
        let dir = tempDir()
        // Seed the spool as if a previous launch persisted two failed envelopes.
        let seed = EnvelopeSpool(directory: dir)
        let now = Date().timeIntervalSince1970
        seed.enqueue(path: "/ingest/v1/errors", payload: body("one"), id: "one", ts: now + 1)
        seed.enqueue(path: "/ingest/v1/errors", payload: body("two"), id: "two", ts: now + 2)

        let poster = StubPoster([.ok()]) // every replay accepted
        let exp = expectation(description: "both replayed")
        poster.onCount = (2, exp.fulfill)
        let spool = EnvelopeSpool(directory: dir)
        let transport = makeTransport(poster: poster, spool: spool)

        transport.drainSpool()
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(poster.requestCount(), 2, "each persisted envelope replayed once")
        XCTAssertEqual(spool.count(), 0, "accepted replays are removed from the spool")
    }

    func testDrainSpoolKeepsFailingEntry() {
        let dir = tempDir()
        let seed = EnvelopeSpool(directory: dir)
        seed.enqueue(path: "/ingest/v1/errors", payload: body("stubborn"), id: "stub",
                     ts: Date().timeIntervalSince1970)

        let poster = StubPoster([.networkError()]) // replay keeps failing
        let exp = expectation(description: "attempts")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let spool = EnvelopeSpool(directory: dir)
        let transport = makeTransport(poster: poster, spool: spool)

        transport.drainSpool()
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        let kept = spool.load()
        XCTAssertEqual(kept.count, 1, "a still-failing replay stays in the spool")
        XCTAssertEqual(kept[0].id, "stub", "re-persisted under the SAME id (no duplicate)")
    }

    // MARK: crash flush — cleared only after ack

    /// Thread-safe one-shot box so the `@Sendable` flush callback can hand a value
    /// back to the test body without a captured-`var` data race.
    private final class ResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Transport.Resolution?
        func set(_ r: Transport.Resolution) { lock.lock(); value = r; lock.unlock() }
        var get: Transport.Resolution? { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testFlushCrashSettledOn2xx() {
        let poster = StubPoster([.ok()])
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        let exp = expectation(description: "resolved")
        let box = ResolutionBox()
        transport.flushCrash(path: "/ingest/v1/errors", body: body("crash")) { r in
            box.set(r); exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(box.get, .settled, "a 2xx settles the crash → source may be cleared")
    }

    func testFlushCrashSettledWhenPersisted() {
        // Persistent failure but a working spool → the body is spooled, so the
        // crash record may be cleared (the spool now owns retry).
        let poster = StubPoster([.networkError()])
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        let exp = expectation(description: "resolved")
        let box = ResolutionBox()
        transport.flushCrash(path: "/ingest/v1/errors", body: body("crash")) { r in
            box.set(r); exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(box.get, .settled, "persisted-to-spool settles the crash source")
        XCTAssertEqual(spool.count(), 1, "the crash body now lives in the spool")
    }

    func testFlushCrashKeepsSourceWhenCannotPersist() {
        // Persistent failure AND no spool → the caller MUST keep its crash record.
        let poster = StubPoster([.networkError()])
        let transport = makeTransport(poster: poster, spool: nil)

        let exp = expectation(description: "resolved")
        let box = ResolutionBox()
        transport.flushCrash(path: "/ingest/v1/errors", body: body("crash")) { r in
            box.set(r); exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(box.get, .keepSource,
                       "undeliverable + unspoolable crash is kept for the next launch")
    }

    // MARK: fail-open

    func testBlankApiKeyIsSilentNoOp() {
        let poster = StubPoster([.ok()])
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool, apiKey: "")

        transport.send(path: "/ingest/v1/errors", body: body("x"))
        let quiet = expectation(description: "no request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(poster.requestCount(), 0, "a blank API key sends nothing")
        XCTAssertEqual(spool.count(), 0)
    }

    func testSessionPathExhaustionNeverSpooled() {
        // A failing session POST is retried in-flight but the spool refuses the
        // session path, so it is never persisted (best-effort live-only).
        let poster = StubPoster([.networkError()])
        let exp = expectation(description: "attempts")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let spool = EnvelopeSpool(directory: tempDir())
        let transport = makeTransport(poster: poster, spool: spool)

        transport.send(path: "/ingest/v1/sessions/start", body: body("{}"))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(spool.count(), 0, "session lifecycle paths are never spooled")
    }
}

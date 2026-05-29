import Foundation

/// Builds and sends AllStak error events. Native frames are sent as runtime
/// instruction addresses plus the process's `debugMeta.images`; the backend
/// resolves them against the uploaded dSYM (via llvm-symbolizer).
public final class AllStakClient: @unchecked Sendable {

    static let sdkName = "allstak-apple"
    static let sdkVersion = "0.1.0"
    private static let maxFrames = 128

    /// `true` when the SDK is initialized inside a unit-test runtime, so session
    /// tracking (which is otherwise never sampled) is skipped — mirroring the
    /// Java SDK's unit-test guard. Covers both the classic XCTest runner
    /// (`XCTestConfigurationFilePath`) and the newer swift-testing harness
    /// (`SWIFT_TESTING_ENABLED`), plus a runtime check for the loaded XCTest
    /// framework as a final, env-independent fallback.
    static let isRunningUnderTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return false
    }()

    private let apiKey: String
    private let host: String
    private let environment: String?
    private let release: String?
    private let autoRegisterRelease: Bool

    /// Reliable transport: bounded retry + exponential backoff + jitter,
    /// Retry-After handling, 401-disable, permanent-4xx drop, and a persistent
    /// on-disk spool for transient failures. Replaces the prior fire-and-forget
    /// `dataTask().resume()` that lost any failed/offline POST forever. All
    /// senders (errors, messages, session start/end, next-launch crash flush,
    /// release registration) route through this single transport.
    let transport: Transport

    /// Ingest paths reused across senders.
    static let pathErrors = "/ingest/v1/errors"
    static let pathReleases = "/ingest/v1/releases"

    /// PII-scrubbing config. When `sendDefaultPii` is `false` (default, Sentry
    /// parity) the email/IPv4 value scrubbers run in addition to the always-on
    /// credit-card + SSN scrubbers and the key denylist.
    private let sanitizer: Sanitizer

    /// Final, in-process filter run at the wire chokepoint BEFORE any POST and
    /// BEFORE the sanitizer. Returning `nil` drops the event; the closure may
    /// mutate the event. Sees real (un-scrubbed) data so a caller can inspect it;
    /// the wire payload is always scrubbed afterwards.
    private let beforeSend: (@Sendable (AllStakErrorEvent) -> AllStakErrorEvent?)?

    /// Release-health session tracker. `nil` when `enableAutoSessionTracking` is
    /// off (or under XCTest), in which case no session id is stamped on events.
    let sessionTracker: SessionTracker?

    /// Per-process distributed-trace id (32 hex). One trace per app launch — every
    /// auto-instrumented outbound request becomes a child span of this head-of-
    /// trace, exactly like the JS SDK's sticky head-of-trace. Lazily stable for the
    /// lifetime of the client so all requests in a launch correlate.
    let traceId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// The global scope shared across this client. Breadcrumbs / user / tags /
    /// contexts / extra accumulated here are attached to every captured event.
    let scope = Scope()

    /// - Parameters:
    ///   - release: explicit release; when `nil`/empty and `autoDetectRelease`
    ///     is `true`, the release is resolved from `ALLSTAK_RELEASE`, then the
    ///     host app's `Info.plist` version, then the SDK version. See
    ///     ``ReleaseResolver``.
    ///   - autoDetectRelease: gates automatic resolution (env / app version /
    ///     SDK version). Default `true`.
    ///   - enableAutoSessionTracking: when `true` (default) the client opens a
    ///     release-health session at init and ends it on graceful shutdown. Set
    ///     `false` to opt out entirely. Automatically suppressed under XCTest.
    public convenience init(apiKey: String, host: String, environment: String?, release: String?,
                            autoDetectRelease: Bool = true, autoRegisterRelease: Bool = true,
                            enableAutoSessionTracking: Bool = true,
                            sendDefaultPii: Bool = false,
                            beforeSend: (@Sendable (AllStakErrorEvent) -> AllStakErrorEvent?)? = nil) {
        // Default production transport: ephemeral URLSession poster + the on-disk
        // envelope spool (drained on init). Tests inject their own via the
        // designated initializer below.
        let normalizedHost = host.hasSuffix("/") ? String(host.dropLast()) : host
        let poster = URLSessionPoster(session: URLSession(configuration: .ephemeral))
        let spool = Self.isRunningUnderTests ? nil : EnvelopeSpool.defaultSpool()
        let transport = Transport(baseURL: normalizedHost, apiKey: apiKey,
                                  poster: poster, spool: spool)
        self.init(apiKey: apiKey, host: host, environment: environment, release: release,
                  autoDetectRelease: autoDetectRelease, autoRegisterRelease: autoRegisterRelease,
                  enableAutoSessionTracking: enableAutoSessionTracking,
                  sendDefaultPii: sendDefaultPii, beforeSend: beforeSend, transport: transport)
    }

    /// Designated initializer with an injectable ``Transport`` (test seam). The
    /// public initializer above wires the production transport.
    init(apiKey: String, host: String, environment: String?, release: String?,
         autoDetectRelease: Bool = true, autoRegisterRelease: Bool = true,
         enableAutoSessionTracking: Bool = true,
         sendDefaultPii: Bool = false,
         beforeSend: (@Sendable (AllStakErrorEvent) -> AllStakErrorEvent?)? = nil,
         transport: Transport) {
        self.apiKey = apiKey
        // Normalize trailing slash so host + path is well-formed.
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.environment = environment
        self.sanitizer = Sanitizer(sendDefaultPii: sendDefaultPii)
        self.beforeSend = beforeSend
        let resolvedRelease = ReleaseResolver.resolve(
            explicit: release,
            autoDetect: autoDetectRelease,
            sdkVersion: Self.sdkVersion)
        self.release = resolvedRelease
        self.autoRegisterRelease = autoRegisterRelease
        self.transport = transport

        // Drain any envelopes spooled by a previous launch (failed/offline POSTs)
        // through the transport, so they get the same retry/backoff/persist
        // treatment. Fully fail-open; never blocks init.
        transport.drainSpool()

        // Release-health sessions are never sampled, but skip them automatically
        // under the test runtime (mirrors the Java SDK's unit-test guard) and
        // honour the opt-out flag.
        if enableAutoSessionTracking && !Self.isRunningUnderTests {
            // Route session start/end through the SAME reliable transport. Session
            // lifecycle paths are best-effort live-only — the spool refuses them
            // (`isPersistablePath`), so a failed session POST is retried in-flight
            // but never persisted/replayed (a stale session would skew durations).
            self.sessionTracker = SessionTracker(
                release: resolvedRelease ?? Self.sdkVersion,
                environment: environment,
                sdkName: Self.sdkName,
                sdkVersion: Self.sdkVersion,
                platform: "cocoa",
                transportEnabled: !apiKey.isEmpty,
                sender: { [transport] path, body in
                    Self.postJSON(transport: transport, path: path, body: body)
                })
        } else {
            self.sessionTracker = nil
        }

        registerRuntimeRelease()
    }

    public func capture(_ error: Error, scope: Scope? = nil) {
        // Handled error → mark the release-health session errored.
        sessionTracker?.recordError()
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        // `scope` nil → buildEvent falls back to the active withScope override,
        // then the global scope.
        send(buildEvent(
            exceptionClass: String(reflecting: type(of: error)),
            message: String(describing: error),
            level: "error",
            addresses: addresses,
            scope: scope))
    }

    public func capture(message: String, level: String = "info", scope: Scope? = nil) {
        // Only error-or-higher messages escalate the session status, matching
        // the reference model (info/debug logs keep the session OK).
        if level == "error" || level == "fatal" {
            sessionTracker?.recordError()
        }
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        send(buildEvent(exceptionClass: "Message", message: message, level: level,
                        addresses: addresses, scope: scope))
    }

    // MARK: - Scope API (global scope)
    //
    // Thin delegations to the global ``scope``; the validation / locking lives
    // there. Kept on the client so ``AllStak`` can route through the live client.

    func addBreadcrumb(type: String, message: String?, category: String? = nil,
                       level: String? = nil, data: [String: Any]? = nil) {
        scope.addBreadcrumb(type: type, message: message, category: category,
                            level: level, data: data)
    }

    func setUser(id: String? = nil, email: String? = nil, ip: String? = nil, username: String? = nil) {
        scope.setUser(id: id, email: email, ip: ip, username: username)
    }

    func clearUser() { scope.clearUser() }

    func setTag(_ key: String, _ value: String) { scope.setTag(key, value) }
    func removeTag(_ key: String) { scope.removeTag(key) }
    func setTags(_ tags: [String: String]) { scope.setTags(tags) }

    func setContext(_ key: String, _ value: [String: Any]?) {
        scope.setContext(key, value: value)
    }

    func setExtra(_ key: String, _ value: Any?) {
        scope.setExtra(key: key, value: value)
    }

    func setExtras(_ extras: [String: Any]) {
        scope.setExtras(extras)
    }

    /// Mutate the global scope inline.
    func configureScope(_ block: (Scope) -> Void) { block(scope) }

    /// Thread-local stack of active override scopes pushed by `withScope`. Using
    /// a thread-local keeps concurrent `withScope` calls on different threads
    /// isolated and lets `capture(...)` discover the innermost active scope
    /// without threading it through every call. Nesting layers (innermost wins).
    private static let activeScopeStackKey = "com.allstak.activeScopeStack"

    private static var activeScopeStack: [Scope] {
        get { (Thread.current.threadDictionary[activeScopeStackKey] as? [Scope]) ?? [] }
        set { Thread.current.threadDictionary[activeScopeStackKey] = newValue }
    }

    /// The innermost `withScope` override active on this thread, if any.
    var activeOverrideScope: Scope? { Self.activeScopeStack.last }

    /// Run `body` with a temporary scope cloned from the global scope; any
    /// `capture(...)` made inside the body (on this thread) uses that clone, and
    /// the clone's mutations never touch the global scope (Sentry/JS `withScope`
    /// isolation). The temporary scope is always popped, even if `body` throws.
    @discardableResult
    func withScope<T>(_ body: (Scope) throws -> T) rethrows -> T {
        let local = scope.clone()
        Self.activeScopeStack.append(local)
        defer { Self.activeScopeStack.removeLast() }
        return try body(local)
    }

    /// Open the release-health session (idempotent, fail-open, never blocks init).
    func startSession(userId: String? = nil) {
        sessionTracker?.start(userId: userId)
    }

    /// End the release-health session on graceful shutdown. Best-effort.
    func endSession(_ status: SessionStatus? = nil) {
        sessionTracker?.end(status)
    }

    /// End a session opened by a PREVIOUS launch (reconciliation). Posts directly
    /// via the transport — independent of this launch's in-memory tracker — so a
    /// session left open by a crash is still closed with the right status.
    func endPreviousSession(sessionId: String, durationMs: Int, status: String) {
        guard !apiKey.isEmpty else { return }
        Self.postJSON(transport: transport, path: SessionTracker.pathEnd,
                      body: ["sessionId": sessionId, "durationMs": durationMs, "status": status])
    }

    // visible for testing — pure payload construction, no network. When `scope`
    // is non-nil (a `withScope` override) it is used; otherwise the client's
    // global scope is attached.
    func buildEvent(exceptionClass: String, message: String, level: String,
                    addresses: [UInt], scope: Scope? = nil) -> AllStakErrorEvent {
        let frames = addresses.prefix(Self.maxFrames).map { addr in
            AllStakFrame(
                function: nil,
                filename: nil,
                instructionAddr: "0x" + String(addr, radix: 16),
                inApp: true)
        }
        // Precedence: explicit scope arg → active `withScope` override → global.
        let snapshot = (scope ?? activeOverrideScope ?? self.scope).snapshot()
        var event = AllStakErrorEvent(
            exceptionClass: exceptionClass,
            message: message,
            // A scope `level` override wins over the call-site level (Sentry/JS
            // scope semantics).
            level: snapshot.level ?? level,
            platform: "cocoa",
            environment: environment,
            release: release,
            sessionId: sessionTracker?.currentSessionId,
            frames: Array(frames),
            debugMeta: AllStakDebugMeta(images: BinaryImageProvider.current()),
            sdkName: Self.sdkName,
            sdkVersion: Self.sdkVersion,
            timestamp: Date().timeIntervalSince1970)
        attachScope(snapshot, to: &event)
        return event
    }

    // visible for testing — builds a fatal event from a persisted crash report,
    // using the crash-time image layout passed in. Crashes carry the global
    // scope (breadcrumbs/user/tags accumulated before the crash).
    func buildCrashEvent(_ report: CrashReport, images: [AllStakBinaryImage]) -> AllStakErrorEvent {
        let frames = report.addresses.prefix(Self.maxFrames).map { addr in
            AllStakFrame(
                function: nil,
                filename: nil,
                instructionAddr: "0x" + String(addr, radix: 16),
                inApp: true)
        }
        var event = AllStakErrorEvent(
            exceptionClass: report.name,
            message: report.message,
            level: "fatal",
            platform: "cocoa",
            environment: environment,
            release: release,
            sessionId: sessionTracker?.currentSessionId,
            frames: Array(frames),
            debugMeta: AllStakDebugMeta(images: images),
            sdkName: Self.sdkName,
            sdkVersion: Self.sdkVersion,
            timestamp: report.timestamp)
        attachScope(scope.snapshot(), to: &event)
        return event
    }

    /// Copy a scope snapshot onto an event. Empty maps/arrays are left `nil` so
    /// the encoder omits them and the existing wire shape is preserved when the
    /// scope is unused. The scope `level` (when set) overrides the event level,
    /// mirroring the Sentry-cocoa / JS scope semantics.
    private func attachScope(_ s: Scope.Snapshot, to event: inout AllStakErrorEvent) {
        event.breadcrumbs = s.breadcrumbs.isEmpty ? nil : s.breadcrumbs
        event.user = s.user
        event.tags = s.tags.isEmpty ? nil : s.tags
        event.contexts = s.contexts.isEmpty ? nil : s.contexts
        event.extra = s.extra.isEmpty ? nil : s.extra
        event.fingerprint = s.fingerprint
    }

    func sendCrash(_ report: CrashReport, images: [AllStakBinaryImage]) {
        send(buildCrashEvent(report, images: images))
    }

    /// Flush a crash report recorded on a PREVIOUS launch through the reliable
    /// transport, invoking `onResolved` once the delivery settles. The crash event
    /// is built + scrubbed here and the resulting bytes are delivered with full
    /// retry/backoff/persist; `onResolved(.settled)` means the caller may delete
    /// the on-disk crash record (2xx / permanent / spooled), `.keepSource` means
    /// keep it for a later launch. Fixes the prior "clear after one unacked send"
    /// bug. If the event is dropped (beforeSend) or cannot be encoded, the source
    /// is settled (it will never become sendable). Fail-open.
    func flushCrash(_ report: CrashReport, images: [AllStakBinaryImage],
                    onResolved: @escaping @Sendable (Transport.Resolution) -> Void) {
        let event = buildCrashEvent(report, images: images)
        guard let body = scrubbedBody(event) else {
            // Dropped by beforeSend or unencodable → never sendable; clear source.
            onResolved(.settled)
            return
        }
        transport.flushCrash(path: Self.pathErrors, body: body, onResolved: onResolved)
    }

    /// The single scrub point on the wire path. Visible for testing. Tries the
    /// full sanitizer first; if it raises for any reason, falls back to a
    /// key-only redaction (still removes the highest-risk secrets) so a scrubber
    /// bug never drops telemetry. Worst case the original event is returned.
    func sanitizedForWire(_ event: AllStakErrorEvent) -> AllStakErrorEvent {
        let result = Result { sanitizer.sanitize(event) }
        switch result {
        case .success(let scrubbed):
            return scrubbed
        case .failure:
            // Fail-open: degrade to key-only redaction rather than dropping.
            return (try? sanitizer.keyOnlyRedaction(event)) ?? event
        }
    }

    private func send(_ rawEvent: AllStakErrorEvent) {
        guard let body = scrubbedBody(rawEvent) else { return } // dropped by beforeSend / unencodable
        transport.send(path: Self.pathErrors, body: body)
    }

    /// Produce the exact ALREADY-SCRUBBED bytes that would be POSTed for an event,
    /// or `nil` when `beforeSend` drops it or encoding fails. Visible for the
    /// crash-flush path so a crash report can be persisted as scrubbed bytes.
    ///
    /// 1. `beforeSend` runs FIRST on the real (un-scrubbed) data — it may mutate
    ///    or drop the event (`nil`). 2. The sanitizer runs AFTER so the wire
    ///    payload is always scrubbed (fail-open to key-only redaction).
    func scrubbedBody(_ rawEvent: AllStakErrorEvent) -> Data? {
        var event = rawEvent
        if let beforeSend {
            guard let filtered = beforeSend(event) else { return nil } // dropped
            event = filtered
        }
        let wireEvent = sanitizedForWire(event)
        return try? JSONEncoder().encode(wireEvent)
    }

    /// JSON POST through the reliable ``Transport`` (retry/backoff/Retry-After/
    /// 401-disable; session paths are not spooled). Used by the session tracker
    /// for `/sessions/start` + `/end`. Nil values are dropped so optional fields
    /// are simply absent from the body.
    static func postJSON(transport: Transport, path: String, body: [String: Any?]) {
        var compact: [String: Any] = [:]
        for (k, v) in body { if let v { compact[k] = v } }
        guard let data = try? JSONSerialization.data(withJSONObject: compact) else { return }
        transport.send(path: path, body: data)
    }

    /// Install automatic outbound HTTP instrumentation (sentry-cocoa-style).
    /// Records redacted `http` breadcrumbs into the client's scope and injects W3C
    /// trace headers using this client's per-launch ``traceId`` + the active
    /// release-health session id. Skips the SDK's own ingest host. Suppressed under
    /// XCTest (so a unit test never patches the test runner's networking) and
    /// behind an empty-API-key guard. Fully fail-open.
    func installHTTPInstrumentation() {
        guard !Self.isRunningUnderTests else { return }
        let traceId = self.traceId
        let sessionProvider = { [weak sessionTracker] in sessionTracker?.currentSessionId }
        HTTPInstrumentation.shared.install(
            scope: scope,
            ingestHost: host,
            sanitizer: sanitizer,
            traceProvider: {
                HTTPInstrumentation.TraceContext(
                    traceId: traceId,
                    sessionId: sessionProvider(),
                    sampled: true)
            })
    }

    private func registerRuntimeRelease() {
        // Skip under the test runtime using the same robust guard the session
        // tracker uses (env var + swift-testing flag + loaded-XCTest fallback),
        // not just `XCTestConfigurationFilePath` — so a test never emits a real
        // release POST through the transport.
        guard autoRegisterRelease,
              !apiKey.isEmpty,
              let release,
              !release.isEmpty,
              !Self.isRunningUnderTests else { return }
        let payload: [String: String?] = [
            "version": release,
            "environment": environment,
            "commitSha": ProcessInfo.processInfo.environment["ALLSTAK_COMMIT_SHA"],
            "branch": ProcessInfo.processInfo.environment["ALLSTAK_BRANCH"],
            "author": nil,
            "message": nil
        ]
        guard let body = try? JSONEncoder().encode(payload) else { return }
        transport.send(path: Self.pathReleases, body: body)
    }
}

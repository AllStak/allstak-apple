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
    private let session: URLSession
    private let autoRegisterRelease: Bool

    /// Release-health session tracker. `nil` when `enableAutoSessionTracking` is
    /// off (or under XCTest), in which case no session id is stamped on events.
    let sessionTracker: SessionTracker?

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
    public init(apiKey: String, host: String, environment: String?, release: String?,
                autoDetectRelease: Bool = true, autoRegisterRelease: Bool = true,
                enableAutoSessionTracking: Bool = true) {
        self.apiKey = apiKey
        // Normalize trailing slash so host + path is well-formed.
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.environment = environment
        let resolvedRelease = ReleaseResolver.resolve(
            explicit: release,
            autoDetect: autoDetectRelease,
            sdkVersion: Self.sdkVersion)
        self.release = resolvedRelease
        let urlSession = URLSession(configuration: .ephemeral)
        self.session = urlSession
        self.autoRegisterRelease = autoRegisterRelease

        // Release-health sessions are never sampled, but skip them automatically
        // under the test runtime (mirrors the Java SDK's unit-test guard) and
        // honour the opt-out flag.
        if enableAutoSessionTracking && !Self.isRunningUnderTests {
            let host = self.host
            let apiKey = self.apiKey
            // Reuse the existing transport/HTTP path: fire-and-forget POST with
            // the same X-AllStak-Key auth header other ingest calls use.
            self.sessionTracker = SessionTracker(
                release: resolvedRelease ?? Self.sdkVersion,
                environment: environment,
                sdkName: Self.sdkName,
                sdkVersion: Self.sdkVersion,
                platform: "cocoa",
                transportEnabled: !apiKey.isEmpty,
                sender: { [session = urlSession] path, body in
                    Self.postJSON(session: session, host: host, apiKey: apiKey,
                                  path: path, body: body)
                })
        } else {
            self.sessionTracker = nil
        }

        registerRuntimeRelease()
    }

    public func capture(_ error: Error) {
        // Handled error → mark the release-health session errored.
        sessionTracker?.recordError()
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        send(buildEvent(
            exceptionClass: String(reflecting: type(of: error)),
            message: String(describing: error),
            level: "error",
            addresses: addresses))
    }

    public func capture(message: String, level: String = "info") {
        // Only error-or-higher messages escalate the session status, matching
        // the reference model (info/debug logs keep the session OK).
        if level == "error" || level == "fatal" {
            sessionTracker?.recordError()
        }
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        send(buildEvent(exceptionClass: "Message", message: message, level: level, addresses: addresses))
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
        Self.postJSON(session: session, host: host, apiKey: apiKey,
                      path: SessionTracker.pathEnd,
                      body: ["sessionId": sessionId, "durationMs": durationMs, "status": status])
    }

    // visible for testing — pure payload construction, no network.
    func buildEvent(exceptionClass: String, message: String, level: String,
                    addresses: [UInt]) -> AllStakErrorEvent {
        let frames = addresses.prefix(Self.maxFrames).map { addr in
            AllStakFrame(
                function: nil,
                filename: nil,
                instructionAddr: "0x" + String(addr, radix: 16),
                inApp: true)
        }
        return AllStakErrorEvent(
            exceptionClass: exceptionClass,
            message: message,
            level: level,
            platform: "cocoa",
            environment: environment,
            release: release,
            sessionId: sessionTracker?.currentSessionId,
            frames: Array(frames),
            debugMeta: AllStakDebugMeta(images: BinaryImageProvider.current()),
            sdkName: Self.sdkName,
            sdkVersion: Self.sdkVersion,
            timestamp: Date().timeIntervalSince1970)
    }

    // visible for testing — builds a fatal event from a persisted crash report,
    // using the crash-time image layout passed in.
    func buildCrashEvent(_ report: CrashReport, images: [AllStakBinaryImage]) -> AllStakErrorEvent {
        let frames = report.addresses.prefix(Self.maxFrames).map { addr in
            AllStakFrame(
                function: nil,
                filename: nil,
                instructionAddr: "0x" + String(addr, radix: 16),
                inApp: true)
        }
        return AllStakErrorEvent(
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
    }

    func sendCrash(_ report: CrashReport, images: [AllStakBinaryImage]) {
        send(buildCrashEvent(report, images: images))
    }

    private func send(_ event: AllStakErrorEvent) {
        guard let url = URL(string: host + "/ingest/v1/errors"),
              let body = try? JSONEncoder().encode(event) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-AllStak-Key")
        req.httpBody = body
        session.dataTask(with: req).resume() // fire-and-forget; never block the host app
    }

    /// Fire-and-forget JSON POST reusing the SDK's existing transport shape
    /// (ephemeral `URLSession`, `X-AllStak-Key` auth, never blocks the host app).
    /// Used by the session tracker for `/sessions/start` and `/sessions/end`.
    /// Nil values are dropped so optional fields are simply absent from the body.
    static func postJSON(session: URLSession, host: String, apiKey: String,
                         path: String, body: [String: Any?]) {
        var compact: [String: Any] = [:]
        for (k, v) in body { if let v { compact[k] = v } }
        guard let url = URL(string: host + path),
              let data = try? JSONSerialization.data(withJSONObject: compact) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5 // short timeout; session I/O must never stall shutdown
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-AllStak-Key")
        req.httpBody = data
        session.dataTask(with: req).resume()
    }

    private func registerRuntimeRelease() {
        guard autoRegisterRelease,
              !apiKey.isEmpty,
              let release,
              !release.isEmpty,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let url = URL(string: host + "/ingest/v1/releases") else { return }
        let payload: [String: String?] = [
            "version": release,
            "environment": environment,
            "commitSha": ProcessInfo.processInfo.environment["ALLSTAK_COMMIT_SHA"],
            "branch": ProcessInfo.processInfo.environment["ALLSTAK_BRANCH"],
            "author": nil,
            "message": nil
        ]
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-AllStak-Key")
        req.httpBody = body
        session.dataTask(with: req).resume()
    }
}

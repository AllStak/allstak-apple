import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// AllStak Apple SDK (iOS / macOS / tvOS) — public entry point.
///
/// ```swift
/// // Explicit release:
/// AllStak.start(apiKey: "astk_live_...",
///               environment: "production", release: "1.4.2")
///
/// // Or omit `release` and let the SDK auto-detect it from the app's own
/// // Info.plist version (e.g. "1.4.2 (123)"):
/// AllStak.start(apiKey: "astk_live_...", environment: "production")
/// AllStak.capture(error)
/// ```
///
/// ## Automatic release detection (honest mobile note)
/// A shipped iOS/macOS app contains no `.git` and no `git` binary, so true
/// runtime git detection is impossible in production. When `release` is omitted
/// and `autoDetectRelease` is `true` (default), the SDK resolves it in this
/// order: `ALLSTAK_RELEASE` env override → the host app's `Info.plist`
/// version (`CFBundleShortVersionString` + `CFBundleVersion`) → the SDK
/// version as a last resort. See ``ReleaseResolver``. To embed a git SHA,
/// inject it at build time via `ALLSTAK_RELEASE` (recommended, see README).
///
/// Native frames are sent as instruction addresses + the process's loaded-image
/// UUIDs; the backend resolves them against the uploaded dSYM.
public enum AllStak {

    nonisolated(unsafe) private static var client: AllStakClient?
    nonisolated(unsafe) private static var lifecycleObservers: [NSObjectProtocol] = []
    private static let lock = NSLock()

    /// Initialize once at app launch.
    ///
    /// - Parameters:
    ///   - release: explicit release identifier. Always wins when non-empty.
    ///     Pass `nil` to let the SDK auto-detect (see ``autoDetectRelease``).
    ///   - autoDetectRelease: when `true` (default) and no explicit `release`
    ///     is given, resolve from `ALLSTAK_RELEASE` / the app's `Info.plist`
    ///     version / the SDK version. When `false`, no release is sent unless
    ///     `release` is explicit.
    /// - Parameter enableAutoSessionTracking: when `true` (default) the SDK opens
    ///   one release-health session per app launch and ends it on graceful
    ///   shutdown (app termination / background→terminate). Set `false` to opt
    ///   out. Session tracking is always fail-open and never blocks launch.
    /// - Parameter sendDefaultPii: when `false` (default, Sentry parity) email
    ///   and IPv4 addresses found inside string values are redacted before the
    ///   event is sent, in addition to the always-on credit-card + SSN scrubbers
    ///   and the sensitive-key denylist. Set `true` to allow email/IP through
    ///   (the financial/identity scrubbers and key denylist stay on regardless).
    ///   The explicit user object you set via ``setUser(id:email:ip:username:)``
    ///   is never value-scrubbed.
    /// - Parameter enableAutoHttpInstrumentation: when `true` (default) the SDK
    ///   automatically observes outbound `URLSession` requests the host app makes,
    ///   recording a redacted `http` breadcrumb (method / redacted URL / status /
    ///   duration / response size, failures included) into the scope and — when a
    ///   trace context exists — attaching W3C `traceparent` + `baggage` headers for
    ///   distributed tracing. The SDK's own ingest host is always skipped. Set
    ///   `false` to opt out. Fully fail-open; never breaks the host's networking.
    /// - Parameter beforeSend: a final filter run on every event at the wire
    ///   chokepoint, BEFORE PII scrubbing. Return `nil` to drop the event, or a
    ///   (possibly mutated) event to send. The hook sees real, un-scrubbed data;
    ///   the wire payload is always scrubbed afterwards.
    public static func start(apiKey: String,
                             host: String = "https://api.allstak.sa",
                             environment: String? = nil,
                             release: String? = nil,
                             autoDetectRelease: Bool = true,
                             autoRegisterRelease: Bool = true,
                             enableCrashCapture: Bool = true,
                             enableAutoSessionTracking: Bool = true,
                             enableAutoHttpInstrumentation: Bool = true,
                             sendDefaultPii: Bool = false,
                             beforeSend: (@Sendable (AllStakErrorEvent) -> AllStakErrorEvent?)? = nil) {
        lock.lock()
        let newClient = AllStakClient(apiKey: apiKey, host: host, environment: environment,
                                      release: release, autoDetectRelease: autoDetectRelease,
                                      autoRegisterRelease: autoRegisterRelease,
                                      enableAutoSessionTracking: enableAutoSessionTracking,
                                      sendDefaultPii: sendDefaultPii,
                                      beforeSend: beforeSend)
        client = newClient
        lock.unlock()

        let store = CrashStore.defaultStore()

        // Reconcile a session left open by a previous launch BEFORE opening this
        // one: if a marker survived, the prior process did not end gracefully, so
        // close that session as crashed (or the status a crash handler stamped).
        reconcilePreviousSession(client: newClient, store: store)

        if enableCrashCapture {
            CrashReporter.install(store: store, client: newClient)
        }

        // Open this launch's session and persist a marker so a crash can be
        // reconciled next launch. Fully fail-open.
        if let tracker = newClient.sessionTracker {
            store.writeOpenSession(OpenSessionMarker(
                sessionId: tracker.start().id,
                startedAt: Date().timeIntervalSince1970,
                status: SessionStatus.ok.wireValue))
            installLifecycleObservers()
        }

        // Install automatic outbound HTTP instrumentation (breadcrumbs + W3C trace
        // propagation). Fail-open and a no-op under XCTest.
        if enableAutoHttpInstrumentation {
            newClient.installHTTPInstrumentation()
        } else {
            HTTPInstrumentation.shared.disable()
        }
    }

    /// End the active session as `crashed` left over from a previous launch.
    private static func reconcilePreviousSession(client: AllStakClient, store: CrashStore) {
        guard let marker = store.openSession() else { return }
        // A surviving marker means the previous process exited without a graceful
        // end. Treat OK as crashed; otherwise honour the stamped terminal status.
        let status = marker.status == SessionStatus.ok.wireValue ? "crashed" : marker.status
        let duration = max(0, Int((Date().timeIntervalSince1970 - marker.startedAt) * 1000))
        client.endPreviousSession(sessionId: marker.sessionId, durationMs: duration, status: status)
        store.clearOpenSession()
    }

    /// Observe app-lifecycle teardown so the session is ended gracefully. UIKit
    /// only; on non-UIKit platforms the next-launch reconciliation is the safety
    /// net. Best-effort and idempotent.
    private static func installLifecycleObservers() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        let end: (Notification) -> Void = { _ in endSessionGracefully() }
        var observers: [NSObjectProtocol] = []
        observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification,
                                        object: nil, queue: nil, using: end))
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: nil, using: end))
        lock.lock(); lifecycleObservers = observers; lock.unlock()
        #endif
    }

    /// End the current session gracefully (clears the crash marker first so it is
    /// NOT reconciled as crashed next launch). Idempotent via the tracker.
    private static func endSessionGracefully() {
        lock.lock(); let c = client; lock.unlock()
        guard let c else { return }
        CrashStore.defaultStore().clearOpenSession()
        c.endSession()
    }

    /// Capture a Swift `Error`.
    public static func capture(_ error: Error) {
        current()?.capture(error)
    }

    /// Capture a free-form message.
    public static func capture(message: String, level: String = "info") {
        current()?.capture(message: message, level: level)
    }

    // MARK: - Scope

    /// Record a breadcrumb on the global scope. Breadcrumbs are a FIFO ring
    /// buffer (default cap 100) attached to subsequent captured events.
    ///
    /// - Parameters:
    ///   - type: one of `default`/`debug`/`error`/`navigation`/`http`/`info`/
    ///     `query`/`transaction`/`ui`/`user`; anything else falls back to
    ///     `default`.
    ///   - category: optional grouping label (e.g. `auth`, `ui.click`).
    ///   - data: optional JSON-encodable structured payload.
    public static func addBreadcrumb(type: String = "default",
                                     message: String? = nil,
                                     category: String? = nil,
                                     level: String? = nil,
                                     data: [String: Any]? = nil) {
        current()?.addBreadcrumb(type: type, message: message, category: category,
                                 level: level, data: data)
    }

    /// Attach a user to subsequent events. Only `id`/`email`/`ip` cross the wire.
    public static func setUser(id: String? = nil, email: String? = nil,
                               ip: String? = nil, username: String? = nil) {
        current()?.setUser(id: id, email: email, ip: ip, username: username)
    }

    /// Detach the current user from the global scope.
    public static func clearUser() { current()?.clearUser() }

    public static func setTag(_ key: String, _ value: String) {
        current()?.setTag(key, value)
    }

    public static func removeTag(_ key: String) { current()?.removeTag(key) }

    public static func setTags(_ tags: [String: String]) { current()?.setTags(tags) }

    /// Set (or, with `nil`, remove) a named context block.
    public static func setContext(_ key: String, _ value: [String: Any]?) {
        current()?.setContext(key, value)
    }

    public static func setExtra(_ key: String, _ value: Any?) {
        current()?.setExtra(key, value)
    }

    public static func setExtras(_ extras: [String: Any]) {
        current()?.setExtras(extras)
    }

    /// Mutate the global scope inline (Sentry-cocoa `configureScope`).
    public static func configureScope(_ block: (Scope) -> Void) {
        current()?.configureScope(block)
    }

    /// Run `body` with a temporary scope cloned from the global scope. Any
    /// `AllStak.capture(...)` made inside the body (on the same thread) attaches
    /// the temporary scope; its mutations never leak into the global scope.
    @discardableResult
    public static func withScope<T>(_ body: (Scope) throws -> T) rethrows -> T? {
        guard let client = current() else { return nil }
        return try client.withScope(body)
    }

    private static func current() -> AllStakClient? {
        lock.lock(); defer { lock.unlock() }
        return client
    }
}

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
    public static func start(apiKey: String,
                             host: String = "https://api.allstak.sa",
                             environment: String? = nil,
                             release: String? = nil,
                             autoDetectRelease: Bool = true,
                             autoRegisterRelease: Bool = true,
                             enableCrashCapture: Bool = true,
                             enableAutoSessionTracking: Bool = true) {
        lock.lock()
        let newClient = AllStakClient(apiKey: apiKey, host: host, environment: environment,
                                      release: release, autoDetectRelease: autoDetectRelease,
                                      autoRegisterRelease: autoRegisterRelease,
                                      enableAutoSessionTracking: enableAutoSessionTracking)
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

    private static func current() -> AllStakClient? {
        lock.lock(); defer { lock.unlock() }
        return client
    }
}

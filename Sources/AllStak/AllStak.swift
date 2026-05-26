import Foundation

/// AllStak Apple SDK (iOS / macOS / tvOS) — public entry point.
///
/// ```swift
/// // Explicit release:
/// AllStak.start(apiKey: "astk_live_...", host: "https://api.allstak.sa",
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
    public static func start(apiKey: String,
                             host: String = "https://api.allstak.sa",
                             environment: String? = nil,
                             release: String? = nil,
                             autoDetectRelease: Bool = true,
                             autoRegisterRelease: Bool = true,
                             enableCrashCapture: Bool = true) {
        lock.lock()
        let newClient = AllStakClient(apiKey: apiKey, host: host, environment: environment,
                                      release: release, autoDetectRelease: autoDetectRelease,
                                      autoRegisterRelease: autoRegisterRelease)
        client = newClient
        lock.unlock()

        if enableCrashCapture {
            CrashReporter.install(store: CrashStore.defaultStore(), client: newClient)
        }
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

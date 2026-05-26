import Foundation

/// AllStak Apple SDK (iOS / macOS / tvOS) — public entry point.
///
/// ```swift
/// AllStak.start(apiKey: "astk_live_...", host: "https://api.allstak.sa",
///               environment: "production", release: "1.4.2")
/// AllStak.capture(error)
/// ```
///
/// Native frames are sent as instruction addresses + the process's loaded-image
/// UUIDs; the backend resolves them against the uploaded dSYM.
public enum AllStak {

    nonisolated(unsafe) private static var client: AllStakClient?
    private static let lock = NSLock()

    /// Initialize once at app launch.
    public static func start(apiKey: String,
                             host: String = "https://api.allstak.sa",
                             environment: String? = nil,
                             release: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        client = AllStakClient(apiKey: apiKey, host: host, environment: environment, release: release)
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

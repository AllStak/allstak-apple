import Foundation

/// Resolves the `release` identifier stamped on every event.
///
/// ## Honest scope note (mobile reality)
/// AllStak's Apple SDK ships *compiled* inside a customer app. A shipped
/// `.app`/`.ipa` contains no `.git` directory and no `git` binary, so there is
/// **no such thing as runtime git detection** in production. The only release
/// identifier that is genuinely *automatic* and *available at runtime* on a
/// device is the app's own version, which the App Store / build process bakes
/// into `Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`).
/// That — not git — is what "automatic release detection" means for a mobile
/// SDK, and it is what we read here.
///
/// Resolution order (highest priority first):
/// 1. Explicit `release` passed to `AllStak.start` — always wins.
/// 2. `ALLSTAK_RELEASE` value supplied via the environment (build-time define
///    forwarded into the process environment, or CI environment in tests).
/// 3. Automatic: the host app's marketing version + build number read from
///    `Bundle.main.infoDictionary` (e.g. `1.4.2 (123)`). Runtime-available,
///    no CI, no git.
/// 4. Fallback: the SDK's own version constant, so `release` is never empty.
///    (SDK version ≠ app version — last resort only.)
///
/// Steps 2–4 are gated by `autoDetectRelease` (default `true`). With
/// auto-detection off, only an explicit `release` is used.
enum ReleaseResolver {

    /// Seam: where the app version is read from. Defaults to the main bundle's
    /// info dictionary; tests inject a fake dictionary to assert ordering
    /// without a real bundle.
    typealias InfoDictionaryProvider = () -> [String: Any]?

    /// Seam: where `ALLSTAK_RELEASE` is read from. Defaults to the process
    /// environment; tests inject a fake.
    typealias EnvironmentProvider = (String) -> String?

    static let defaultInfoDictionary: InfoDictionaryProvider = {
        Bundle.main.infoDictionary
    }

    static let defaultEnvironment: EnvironmentProvider = { key in
        ProcessInfo.processInfo.environment[key]
    }

    /// Pure resolution logic (no network, no globals) — directly unit-testable.
    ///
    /// - Parameters:
    ///   - explicit: the `release` the caller passed to `start`, if any.
    ///   - autoDetect: when `false`, steps 2–4 are skipped entirely.
    ///   - sdkVersion: last-resort fallback (the SDK's own version).
    ///   - infoDictionary: seam for `Bundle.main.infoDictionary`.
    ///   - environment: seam for `ProcessInfo` env lookups.
    static func resolve(explicit: String?,
                        autoDetect: Bool,
                        sdkVersion: String,
                        infoDictionary: InfoDictionaryProvider = defaultInfoDictionary,
                        environment: EnvironmentProvider = defaultEnvironment) -> String? {
        // 1. Explicit always wins, regardless of autoDetect.
        if let explicit, !explicit.isEmpty {
            return explicit
        }

        guard autoDetect else {
            // Auto-detection disabled: respect the caller's intent and send no
            // release (nil) rather than silently inventing one.
            return nil
        }

        // 2. Build-time / CI environment override.
        if let env = environment("ALLSTAK_RELEASE"),
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }

        // 3. Automatic: the host app's own version from Info.plist.
        if let appVersion = appVersion(from: infoDictionary()) {
            return appVersion
        }

        // 4. Last resort: the SDK's own version so `release` is never empty.
        return sdkVersion
    }

    /// Formats the app version from an info dictionary as
    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `1.4.2 (123)`.
    /// Returns `nil` when no marketing version is present (e.g. a SwiftPM test
    /// bundle, where `CFBundleShortVersionString` is typically absent).
    static func appVersion(from info: [String: Any]?) -> String? {
        guard let info else { return nil }
        guard let short = info["CFBundleShortVersionString"] as? String,
              !short.isEmpty else {
            return nil
        }
        if let build = info["CFBundleVersion"] as? String,
           !build.isEmpty,
           build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}

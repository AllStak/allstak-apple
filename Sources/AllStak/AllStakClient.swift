import Foundation

/// Builds and sends AllStak error events. Native frames are sent as runtime
/// instruction addresses plus the process's `debugMeta.images`; the backend
/// resolves them against the uploaded dSYM (via llvm-symbolizer).
public final class AllStakClient: @unchecked Sendable {

    static let sdkName = "allstak-apple"
    static let sdkVersion = "0.1.0"
    private static let maxFrames = 128

    private let apiKey: String
    private let host: String
    private let environment: String?
    private let release: String?
    private let session: URLSession

    /// - Parameters:
    ///   - release: explicit release; when `nil`/empty and `autoDetectRelease`
    ///     is `true`, the release is resolved from `ALLSTAK_RELEASE`, then the
    ///     host app's `Info.plist` version, then the SDK version. See
    ///     ``ReleaseResolver``.
    ///   - autoDetectRelease: gates automatic resolution (env / app version /
    ///     SDK version). Default `true`.
    public init(apiKey: String, host: String, environment: String?, release: String?,
                autoDetectRelease: Bool = true) {
        self.apiKey = apiKey
        // Normalize trailing slash so host + path is well-formed.
        self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
        self.environment = environment
        self.release = ReleaseResolver.resolve(
            explicit: release,
            autoDetect: autoDetectRelease,
            sdkVersion: Self.sdkVersion)
        self.session = URLSession(configuration: .ephemeral)
    }

    public func capture(_ error: Error) {
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        send(buildEvent(
            exceptionClass: String(reflecting: type(of: error)),
            message: String(describing: error),
            level: "error",
            addresses: addresses))
    }

    public func capture(message: String, level: String = "info") {
        let addresses = Thread.callStackReturnAddresses.map { $0.uintValue }
        send(buildEvent(exceptionClass: "Message", message: message, level: level, addresses: addresses))
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
}

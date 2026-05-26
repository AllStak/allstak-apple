import Foundation

/// One persisted crash, written when the app is dying and read + sent on the next
/// launch (you can't reliably send during a crash).
public struct CrashReport: Codable, Sendable, Equatable {
    public let kind: String          // "nsexception" | "signal"
    public let name: String          // exception name or signal name
    public let message: String
    public let addresses: [UInt]     // call-stack return addresses (runtime)
    public let timestamp: Double

    public init(kind: String, name: String, message: String, addresses: [UInt], timestamp: Double) {
        self.kind = kind
        self.name = name
        self.message = message
        self.addresses = addresses
        self.timestamp = timestamp
    }
}

/// On-disk store for crash reports + the per-launch binary-image layout (so a
/// crash captured in a previous launch is symbolicated against THAT launch's
/// ASLR-slid image addresses, not the new launch's).
public final class CrashStore: @unchecked Sendable {

    private let directory: URL
    private let imagesURL: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        self.imagesURL = directory.appendingPathComponent("images.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Fixed location of the async-signal-safe signal-crash record (see
    /// SignalCrashHandler). Pre-opened at install time and written by the handler.
    public func signalCrashFileURL() -> URL {
        directory.appendingPathComponent(SignalCrashHandler.recordFilename)
    }

    /// Read + remove any persisted signal-crash record from a previous launch,
    /// converted to the shared `CrashReport`. Normal context (the handler itself
    /// only writes the raw record). Returns nil if there's nothing pending.
    public func pendingSignalReport() -> CrashReport? {
        SignalCrashHandler.readPendingReport(crashFileURL: signalCrashFileURL())
    }

    /// Default location: <caches>/com.allstak/crashes
    public static func defaultStore() -> CrashStore {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CrashStore(directory: base.appendingPathComponent("com.allstak/crashes"))
    }

    public func write(_ report: CrashReport) throws {
        let url = directory.appendingPathComponent(UUID().uuidString + ".crash")
        let data = try JSONEncoder().encode(report)
        try data.write(to: url, options: .atomic)
    }

    public func pendingReports() -> [CrashReport] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "crash" }
            .compactMap { try? JSONDecoder().decode(CrashReport.self, from: Data(contentsOf: $0)) }
    }

    public func clearReports() {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "crash" { try? fileManager.removeItem(at: f) }
    }

    /// Persist the current launch's loaded-image layout (called AFTER pending
    /// reports are processed, so the prior layout is still readable for them).
    public func saveSessionImages(_ images: [AllStakBinaryImage]) {
        if let data = try? JSONEncoder().encode(images) {
            try? data.write(to: imagesURL, options: .atomic)
        }
    }

    public func sessionImages() -> [AllStakBinaryImage] {
        guard let data = try? Data(contentsOf: imagesURL),
              let images = try? JSONDecoder().decode([AllStakBinaryImage].self, from: data) else {
            return []
        }
        return images
    }
}

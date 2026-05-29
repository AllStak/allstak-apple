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

/// The persisted "open session" marker. Written when a release-health session
/// starts and removed on graceful end; if a launch finds one left over, the
/// previous process died without ending its session and the prior session is
/// ended as `crashed` (or whatever terminal status the crash handler stamped).
public struct OpenSessionMarker: Codable, Sendable, Equatable {
    public let sessionId: String
    public let startedAt: Double   // seconds since epoch
    /// Terminal status a crash handler stamped before the process died. When the
    /// process exits cleanly the marker is removed first, so a marker that
    /// survives to the next launch implies an abnormal/crashed end.
    public let status: String      // SessionStatus wire value

    public init(sessionId: String, startedAt: Double, status: String) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.status = status
    }
}

/// On-disk store for crash reports + the per-launch binary-image layout (so a
/// crash captured in a previous launch is symbolicated against THAT launch's
/// ASLR-slid image addresses, not the new launch's).
public final class CrashStore: @unchecked Sendable {

    private let directory: URL
    private let imagesURL: URL
    private let openSessionURL: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        self.imagesURL = directory.appendingPathComponent("images.json")
        self.openSessionURL = directory.appendingPathComponent("open-session.json")
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

    /// Non-destructively parse the pending signal-crash record (does NOT delete
    /// the file). Used by the next-launch flush so the signal record is removed
    /// only AFTER the transport acknowledges it — never on an unacked send. A
    /// record that fails to parse is removed immediately (it can never be sent).
    public func peekSignalReport() -> CrashReport? {
        SignalCrashHandler.peekPendingReport(crashFileURL: signalCrashFileURL())
    }

    /// Remove the pending signal-crash record (after the transport acknowledges it).
    public func removeSignalReport() {
        try? fileManager.removeItem(at: signalCrashFileURL())
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
        pendingReportsWithURLs().map { $0.report }
    }

    /// Pending crash reports paired with their backing file URL, so a caller can
    /// remove an INDIVIDUAL report only after it has been acknowledged by the
    /// transport (2xx / permanent / spooled) — fixing the "clear after one
    /// unacked send" bug where every report was dropped after a single fire-and-
    /// forget POST regardless of HTTP success.
    public func pendingReportsWithURLs() -> [(url: URL, report: CrashReport)] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "crash" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? JSONDecoder().decode(CrashReport.self, from: data) else { return nil }
                return (url, report)
            }
    }

    /// Remove a single crash report file (after the transport acknowledges it).
    public func removeReport(at url: URL) {
        try? fileManager.removeItem(at: url)
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

    // MARK: - Open-session marker (crash-aware session lifecycle)

    /// Persist the currently-open session so a crash that prevents a graceful
    /// `/sessions/end` can still be reconciled on the next launch.
    public func writeOpenSession(_ marker: OpenSessionMarker) {
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: openSessionURL, options: .atomic)
        }
    }

    /// Read the open-session marker left by a previous launch, if any.
    public func openSession() -> OpenSessionMarker? {
        guard let data = try? Data(contentsOf: openSessionURL),
              let marker = try? JSONDecoder().decode(OpenSessionMarker.self, from: data) else {
            return nil
        }
        return marker
    }

    /// Bump the persisted open-session marker's status (e.g. to `crashed`) so the
    /// next launch ends the prior session with the right terminal status. Best-
    /// effort; never throws. A no-op if no marker is present.
    public func markOpenSession(status: String) {
        guard let current = openSession() else { return }
        writeOpenSession(OpenSessionMarker(sessionId: current.sessionId,
                                           startedAt: current.startedAt,
                                           status: status))
    }

    /// Remove the open-session marker on graceful session end.
    public func clearOpenSession() {
        try? fileManager.removeItem(at: openSessionURL)
    }
}

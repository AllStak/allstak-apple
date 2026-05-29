import XCTest
@testable import AllStak

/// End-to-end of the next-launch crash flush THROUGH the reliable transport:
/// a crash record on disk is cleared ONLY after the transport acknowledges it
/// (fixing the prior "clear after one unacked send" bug), and is KEPT when the
/// flush can neither deliver nor persist.
final class CrashFlushTransportTests: XCTestCase {

    private func tempStoreDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-crashflush-test-" + UUID().uuidString)
    }

    /// Minimal scripted poster (same shape as TransportTests', kept local so the
    /// two suites stay independent).
    private final class Poster: HTTPPoster, @unchecked Sendable {
        let alwaysFail: Bool
        private let lock = NSLock()
        private(set) var count = 0
        private var fulfilled = false
        var onCount: (count: Int, fulfill: () -> Void)?
        init(alwaysFail: Bool) { self.alwaysFail = alwaysFail }
        func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        /// Sync bump kept out of the async method so the lock is never held across
        /// an await. Fires the target expectation exactly once (at-or-after the
        /// target count) to avoid an XCTest multiple-fulfill violation.
        private func bump() -> (() -> Void)? {
            lock.lock(); defer { lock.unlock() }
            count += 1
            guard let t = onCount, count >= t.count, !fulfilled else { return nil }
            fulfilled = true
            return t.fulfill
        }
        func post(url: URL, headers: [String: String], body: Data) async throws
            -> (status: Int, retryAfter: String?) {
            if let fire = bump() { fire() }
            if alwaysFail { throw URLError(.notConnectedToInternet) }
            return (200, nil)
        }
    }

    private func makeClient(transport: Transport) -> AllStakClient {
        // enableAutoSessionTracking:false + the test-runtime guard keep this a
        // pure error/crash client with the injected transport.
        AllStakClient(apiKey: "k", host: "https://h.test", environment: "test",
                      release: "1.0.0", enableAutoSessionTracking: false,
                      transport: transport)
    }

    func testCrashFileClearedAfter2xxAck() {
        let dir = tempStoreDir()
        let store = CrashStore(directory: dir)
        try? store.write(CrashReport(kind: "nsexception", name: "NSRangeException",
                                     message: "oob", addresses: [0x1, 0x2],
                                     timestamp: 1_700_000_000))
        store.saveSessionImages(BinaryImageProvider.current())
        XCTAssertEqual(store.pendingReports().count, 1)

        let poster = Poster(alwaysFail: false)
        let exp = expectation(description: "posted")
        poster.onCount = (1, exp.fulfill)
        let transport = Transport(baseURL: "https://h.test", apiKey: "k", poster: poster,
                                  spool: nil, sleep: { _ in }, randomUnit: { 0.5 })
        let client = makeClient(transport: transport)

        CrashReporter.sendPending(store: store, client: client)
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(store.pendingReports().count, 0,
                       "the crash file is cleared ONLY after the 2xx ack")
    }

    func testCrashFileKeptWhenSendFailsAndNoSpool() {
        let dir = tempStoreDir()
        let store = CrashStore(directory: dir)
        try? store.write(CrashReport(kind: "nsexception", name: "NSRangeException",
                                     message: "oob", addresses: [0x1],
                                     timestamp: 1_700_000_000))
        store.saveSessionImages(BinaryImageProvider.current())

        // Always-fail poster + NO spool → the crash must NOT be cleared (the old
        // bug cleared it after the first unacked send).
        let poster = Poster(alwaysFail: true)
        let exp = expectation(description: "attempts exhausted")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let transport = Transport(baseURL: "https://h.test", apiKey: "k", poster: poster,
                                  spool: nil, sleep: { _ in }, randomUnit: { 0.5 })
        let client = makeClient(transport: transport)

        CrashReporter.sendPending(store: store, client: client)
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(store.pendingReports().count, 1,
                       "an unacked, unspoolable crash is KEPT for the next launch")
    }

    func testCrashFileClearedWhenSpooledOnFailure() {
        let dir = tempStoreDir()
        let store = CrashStore(directory: dir)
        try? store.write(CrashReport(kind: "nsexception", name: "NSRangeException",
                                     message: "oob", addresses: [0x1],
                                     timestamp: 1_700_000_000))
        store.saveSessionImages(BinaryImageProvider.current())

        // Always-fail poster + a working spool → the body is spooled, so the crash
        // file is cleared (the spool now owns the retry/replay).
        let poster = Poster(alwaysFail: true)
        let exp = expectation(description: "attempts exhausted")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let spool = EnvelopeSpool(directory: dir.appendingPathComponent("spool"))
        let transport = Transport(baseURL: "https://h.test", apiKey: "k", poster: poster,
                                  spool: spool, sleep: { _ in }, randomUnit: { 0.5 })
        let client = makeClient(transport: transport)

        CrashReporter.sendPending(store: store, client: client)
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        XCTAssertEqual(store.pendingReports().count, 0,
                       "the crash file is cleared once its body is safely in the spool")
        XCTAssertEqual(spool.count(), 1, "the crash body survives in the persistent spool")
    }
}

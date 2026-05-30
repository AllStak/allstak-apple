import XCTest
@testable import AllStak

final class DiagnosticsTests: XCTestCase {

    final class StubPoster: HTTPPoster, @unchecked Sendable {
        struct Response {
            let status: Int?
            let retryAfter: String?
            let throwsError: Bool
            static func ok() -> Response { Response(status: 200, retryAfter: nil, throwsError: false) }
            static func code(_ status: Int, retryAfter: String? = nil) -> Response {
                Response(status: status, retryAfter: retryAfter, throwsError: false)
            }
            static func networkError() -> Response {
                Response(status: nil, retryAfter: nil, throwsError: true)
            }
        }

        private let lock = NSLock()
        private var script: [Response]
        private var index = 0
        private(set) var requestCount = 0
        var onCount: (count: Int, fulfill: () -> Void)?

        init(_ script: [Response]) {
            self.script = script
        }

        private func record() -> (response: Response, target: (count: Int, fulfill: () -> Void)?, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            requestCount += 1
            let response = index < script.count ? script[index] : (script.last ?? .ok())
            if index < script.count { index += 1 }
            return (response, onCount, requestCount)
        }

        func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, retryAfter: String?) {
            let (response, target, count) = record()
            if let target, count >= target.count { target.fulfill() }
            if response.throwsError { throw URLError(.notConnectedToInternet) }
            return (response.status ?? 200, response.retryAfter)
        }
    }

    private let noSleep: @Sendable (Double) async -> Void = { _ in }

    private func makeClient(poster: StubPoster) -> AllStakClient {
        let transport = Transport(
            baseURL: "https://h.test",
            apiKey: "k",
            poster: poster,
            spool: nil,
            sleep: noSleep,
            randomUnit: { 0.5 })
        return AllStakClient(
            apiKey: "k",
            host: "https://h.test",
            environment: "test",
            release: "1.0.0",
            autoRegisterRelease: false,
            enableAutoSessionTracking: false,
            transport: transport)
    }

    func testClientDiagnosticsArePrivacySafeCountersOnly() {
        let poster = StubPoster([.ok()])
        let posted = expectation(description: "posted")
        poster.onCount = (1, posted.fulfill)
        let client = makeClient(poster: poster)
        client.addBreadcrumb(type: "default",
                             message: "password secret-value",
                             data: ["Authorization": "Bearer secret-value"])

        client.capture(message: "secret-value", level: "info")
        wait(for: [posted], timeout: 2)

        let diagnostics = client.diagnostics()
        let raw = String(describing: diagnostics)
        XCTAssertEqual(diagnostics.eventsCaptured, 1)
        XCTAssertEqual(diagnostics.eventsSent, 1)
        XCTAssertEqual(diagnostics.breadcrumbCount, 1)
        XCTAssertFalse(raw.contains("secret-value"))
        XCTAssertFalse(raw.contains("Authorization"))
    }

    func testBeforeSendDropIsCountedAsDropped() {
        let poster = StubPoster([.ok()])
        let transport = Transport(
            baseURL: "https://h.test",
            apiKey: "k",
            poster: poster,
            spool: nil,
            sleep: noSleep,
            randomUnit: { 0.5 })
        let client = AllStakClient(
            apiKey: "k",
            host: "https://h.test",
            environment: "test",
            release: "1.0.0",
            autoRegisterRelease: false,
            enableAutoSessionTracking: false,
            beforeSend: { _ in nil },
            transport: transport)

        client.capture(message: "drop-me")

        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        let diagnostics = client.diagnostics()
        XCTAssertEqual(diagnostics.eventsCaptured, 1)
        XCTAssertEqual(diagnostics.eventsDropped, 1)
        XCTAssertEqual(diagnostics.eventsSent, 0)
    }

    func testTransportDiagnosticsTrackRetryRateLimitAndPersistence() {
        let poster = StubPoster([.code(429, retryAfter: "0")])
        let exp = expectation(description: "attempts")
        poster.onCount = (RetryPolicy.maxRetries + 1, exp.fulfill)
        let spool = EnvelopeSpool(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-diagnostics-" + UUID().uuidString))
        let transport = Transport(
            baseURL: "https://h.test",
            apiKey: "k",
            poster: poster,
            spool: spool,
            sleep: noSleep,
            randomUnit: { 0.5 })

        transport.send(path: "/ingest/v1/errors", body: Data("rate".utf8))
        wait(for: [exp], timeout: 2)
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        let stats = transport.stats()
        XCTAssertEqual(stats.eventsFailed, 1)
        XCTAssertEqual(stats.eventsPersisted, 1)
        XCTAssertEqual(stats.retryAttempts, RetryPolicy.maxRetries)
        XCTAssertEqual(stats.rateLimitedCount, RetryPolicy.maxRetries + 1)
        XCTAssertEqual(stats.queueSize, 1)
    }

    func testPublicFlushAndCloseAreIdempotentAndPrivacySafe() async {
        _ = await AllStak.close(timeout: 0.01)
        let emptyFlush = await AllStak.flush(timeout: 0.01)
        XCTAssertTrue(emptyFlush)

        AllStak.start(
            apiKey: "",
            host: "https://h.test",
            environment: "test",
            release: "1.0.0",
            autoRegisterRelease: false,
            enableCrashCapture: false,
            enableAutoSessionTracking: false,
            enableAutoHttpInstrumentation: false,
            enableAppHangTracking: false,
            enableWatchdogTerminationTracking: false,
            enableMetricKit: false,
            enableAutoBreadcrumbs: false)
        AllStak.addBreadcrumb(message: "password secret-value",
                              data: ["Authorization": "Bearer secret-value"])
        AllStak.capture(message: "secret-value")

        let diagnostics = AllStak.getDiagnostics()
        let raw = String(describing: diagnostics)
        XCTAssertEqual(diagnostics.eventsCaptured, 1)
        XCTAssertFalse(raw.contains("secret-value"))
        XCTAssertFalse(raw.contains("Authorization"))
        let firstClose = await AllStak.close(timeout: 0.01)
        let secondClose = await AllStak.close(timeout: 0.01)
        XCTAssertTrue(firstClose)
        XCTAssertTrue(secondClose)
    }
}

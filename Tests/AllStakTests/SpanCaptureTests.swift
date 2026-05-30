import XCTest
@testable import AllStak

final class SpanCaptureTests: XCTestCase {

    private final class RecordingPoster: HTTPPoster, @unchecked Sendable {
        private let queue = DispatchQueue(label: "allstak.span-capture-test.poster")
        private var requests: [(url: URL, headers: [String: String], body: Data)] = []

        func recordedRequests() -> [(url: URL, headers: [String: String], body: Data)] {
            queue.sync { requests }
        }

        func post(url: URL, headers: [String: String], body: Data) async throws
            -> (status: Int, retryAfter: String?) {
            queue.sync {
                requests.append((url, headers, body))
            }
            return (202, nil)
        }
    }

    private func makeClient(poster: RecordingPoster) -> AllStakClient {
        let transport = Transport(
            baseURL: "https://h.test",
            apiKey: "k",
            poster: poster,
            spool: nil,
            sleep: { _ in },
            randomUnit: { 0.5 })
        return AllStakClient(
            apiKey: "k",
            host: "https://h.test",
            environment: "test",
            release: "1.0.0",
            enableAutoSessionTracking: false,
            transport: transport)
    }

    func testCaptureSpanPostsW3CNormalizedSpanBatch() async throws {
        let poster = RecordingPoster()
        let client = makeClient(poster: poster)

        client.captureSpan(
            traceId: "550E8400-E29B-41D4-A716-446655440000",
            spanId: "ABCDEFABCDEF1234",
            parentSpanId: "1234567890ABCDEF",
            operation: "db.sqlite.query",
            description: "SELECT 1",
            status: "ok",
            durationMs: 3,
            startTimeMillis: 1_700_000_000_000,
            endTimeMillis: 1_700_000_000_003,
            service: "certification-apple",
            tags: ["db.system": "sqlite"],
            data: "safe")

        let flushed = await client.flush(timeout: 2)
        XCTAssertTrue(flushed)
        let request = try XCTUnwrap(poster.recordedRequests().first)
        XCTAssertEqual(request.url.path, "/ingest/v1/spans")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let spans = try XCTUnwrap(json["spans"] as? [[String: Any]])
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span["traceId"] as? String, "550e8400e29b41d4a716446655440000")
        XCTAssertEqual(span["spanId"] as? String, "abcdefabcdef1234")
        XCTAssertEqual(span["parentSpanId"] as? String, "1234567890abcdef")
        XCTAssertEqual(span["operation"] as? String, "db.sqlite.query")
        XCTAssertEqual(span["service"] as? String, "certification-apple")
    }

    func testCaptureSpanSanitizesTagsAttributesAndData() async throws {
        let poster = RecordingPoster()
        let client = makeClient(poster: poster)

        client.captureSpan(
            traceId: String(repeating: "a", count: 32),
            spanId: String(repeating: "b", count: 16),
            operation: "http.client",
            description: "GET https://example.invalid",
            status: "ok",
            durationMs: 1,
            startTimeMillis: 1,
            endTimeMillis: 2,
            tags: ["authorization": "Bearer should_not_leak"],
            data: "card 4242424242424242",
            attributes: ["nested": ["apiKey": "should_not_leak"]])

        let flushed = await client.flush(timeout: 2)
        XCTAssertTrue(flushed)
        let request = try XCTUnwrap(poster.recordedRequests().first)
        let serialized = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(serialized.contains("should_not_leak"))
        XCTAssertFalse(serialized.contains("4242424242424242"))
        XCTAssertTrue(serialized.contains(Sanitizer.redactedMarker))
    }
}

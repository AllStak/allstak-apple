import XCTest
@testable import AllStak

/// Outbound HTTP auto-instrumentation: a captured request lands a redacted `http`
/// breadcrumb, the SDK's own ingest host is skipped (no recursion), W3C
/// `traceparent` + `baggage` headers are injected, opt-out disables interception,
/// and network failures are captured. The end-to-end tests drive a real
/// ``AllStakURLProtocol`` against an offline mock backend protocol (no socket).
final class HTTPInstrumentationTests: XCTestCase {

    /// Route the request that AllStakURLProtocol forwards into the offline mock
    /// backend, so no test ever touches a real socket (Foundation's
    /// `URLProtocol.registerClass` registry is NOT inherited by custom sessions —
    /// only `URLSession.shared` uses it — so we must inject the mock via this seam).
    override func setUp() {
        super.setUp()
        MockBackendURLProtocol.reset()
        AllStakURLProtocol.forwardingProtocolClassesOverride = [MockBackendURLProtocol.self]
    }

    /// Reset the shared coordinator between tests so config from one test never
    /// leaks into another. Re-installing only refreshes config; we toggle it off
    /// in tearDown.
    override func tearDown() {
        HTTPInstrumentation.shared.disable()
        AllStakURLProtocol.forwardingProtocolClassesOverride = nil
        MockBackendURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Offline mock backend — serves the request the AllStakURLProtocol forwards.

    /// A second `URLProtocol` registered ONLY into the test session's
    /// `protocolClasses` (after AllStakURLProtocol), so the request our protocol
    /// forwards is answered offline. Mirrors the StubPoster pattern used by the
    /// transport tests: no real network is ever touched.
    final class MockBackendURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var nextStatus = 200
        nonisolated(unsafe) static var nextBody = Data("hello-body".utf8)
        nonisolated(unsafe) static var failWithError = false
        nonisolated(unsafe) static var lastForwardedHeaders: [String: String]?

        static func reset() {
            nextStatus = 200
            nextBody = Data("hello-body".utf8)
            failWithError = false
            lastForwardedHeaders = nil
        }

        override class func canInit(with request: URLRequest) -> Bool {
            // Only handle the request the AllStakURLProtocol forwarded (it carries
            // the handled marker); plain requests are left to AllStakURLProtocol.
            URLProtocol.property(forKey: "com.allstak.httpInstrumentation.handled", in: request) != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastForwardedHeaders = request.allHTTPHeaderFields
            if Self.failWithError {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.nextStatus,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(Self.nextBody.count)"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.nextBody)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// The outer session the "host app" uses: only ``AllStakURLProtocol`` is in
    /// its `protocolClasses`, so it intercepts the outbound request. The forwarded
    /// (handled-marked) request is then answered by ``MockBackendURLProtocol`` via
    /// the forwarding-session override set in `setUp` — never a real socket.
    private func instrumentedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AllStakURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Install instrumentation against a fresh scope (kept alive by the caller via
    /// the returned strong reference, since the coordinator holds it weakly).
    @discardableResult
    private func install(scope: Scope, ingestHost: String = "https://api.allstak.sa",
                         sendDefaultPii: Bool = false,
                         trace: HTTPInstrumentation.TraceContext? =
                            HTTPInstrumentation.TraceContext(traceId: "0123456789abcdef0123456789abcdef",
                                                             sessionId: "sess-123")) -> Scope {
        HTTPInstrumentation.shared.install(
            scope: scope,
            ingestHost: ingestHost,
            sanitizer: Sanitizer(sendDefaultPii: sendDefaultPii),
            traceProvider: { trace })
        return scope
    }

    // MARK: 1. A captured outbound request produces a redacted breadcrumb

    func testCapturedRequestProducesRedactedBreadcrumb() throws {
        let scope = Scope()
        install(scope: scope)
        MockBackendURLProtocol.nextStatus = 200

        let session = instrumentedSession()
        let url = URL(string: "https://example.com/api/users?token=supersecret&id=42")!
        let exp = expectation(description: "request completes")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        session.dataTask(with: req) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 5)

        let crumbs = scope.breadcrumbs
        let http = try XCTUnwrap(crumbs.first { $0.type == "http" }, "must record an http breadcrumb")
        XCTAssertEqual(http.category, "http")
        XCTAssertEqual(http.level, "info", "2xx is info level")
        XCTAssertEqual(http.data?["method"], .string("POST"))
        XCTAssertEqual(http.data?["status_code"], .int(200))
        // Redaction: the query string (with the token) MUST be gone from the URL.
        let recordedUrl = http.data?["url"]
        if case .string(let s)? = recordedUrl {
            XCTAssertFalse(s.contains("token"), "query string must be stripped")
            XCTAssertFalse(s.contains("supersecret"), "secret query value must be gone")
            XCTAssertTrue(s.contains("example.com/api/users"), "host + path preserved")
        } else {
            XCTFail("breadcrumb url must be a string")
        }
        XCTAssertNotNil(http.message)
        XCTAssertTrue(http.message?.contains("200") ?? false)
    }

    func testBreadcrumbScrubsPiiInPath() throws {
        let scope = Scope()
        install(scope: scope) // sendDefaultPii false → emails scrubbed
        let session = instrumentedSession()
        // Email embedded in the REST path must be value-scrubbed.
        let url = URL(string: "https://example.com/users/alice@example.com/profile")!
        let exp = expectation(description: "done")
        session.dataTask(with: url) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 5)

        let http = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "http" })
        if case .string(let s)? = http.data?["url"] {
            XCTAssertFalse(s.contains("alice@example.com"), "email in path must be redacted")
            XCTAssertTrue(s.contains(Sanitizer.redactedMarker))
        } else { XCTFail("url not a string") }
    }

    // MARK: 2. Own-ingest host is skipped (no recursion / self-observation)

    func testOwnIngestHostIsSkipped() {
        let scope = Scope()
        install(scope: scope, ingestHost: "https://api.allstak.sa")

        let ingestURL = URL(string: "https://api.allstak.sa/ingest/v1/errors")!
        XCTAssertFalse(AllStakURLProtocol.canInit(with: URLRequest(url: ingestURL)),
                       "the SDK's own ingest host must not be intercepted")

        // A different host IS intercepted.
        let other = URL(string: "https://example.com/x")!
        XCTAssertTrue(AllStakURLProtocol.canInit(with: URLRequest(url: other)))
    }

    func testIsOwnIngestMatchesHostWithBareConfig() {
        let scope = Scope()
        install(scope: scope, ingestHost: "api.allstak.sa") // bare host, no scheme
        XCTAssertTrue(HTTPInstrumentation.shared.isOwnIngest(
            URL(string: "https://api.allstak.sa/ingest/v1/errors")!))
        XCTAssertFalse(HTTPInstrumentation.shared.isOwnIngest(
            URL(string: "https://other.host/x")!))
    }

    func testAlreadyHandledRequestDeclined() {
        let scope = Scope()
        install(scope: scope)
        let req = NSMutableURLRequest(url: URL(string: "https://example.com/x")!)
        URLProtocol.setProperty(true, forKey: "com.allstak.httpInstrumentation.handled", in: req)
        XCTAssertFalse(AllStakURLProtocol.canInit(with: req as URLRequest),
                       "the protocol must not re-intercept the request it forwards")
    }

    func testNonHttpSchemeDeclined() {
        let scope = Scope()
        install(scope: scope)
        XCTAssertFalse(AllStakURLProtocol.canInit(
            with: URLRequest(url: URL(string: "file:///tmp/x")!)))
        XCTAssertFalse(AllStakURLProtocol.canInit(
            with: URLRequest(url: URL(string: "ws://example.com/x")!)))
    }

    // MARK: 3. W3C traceparent + baggage injected

    func testTraceHeadersInjectedEndToEnd() throws {
        let scope = Scope()
        install(scope: scope,
                trace: HTTPInstrumentation.TraceContext(
                    traceId: "0123456789abcdef0123456789abcdef",
                    sessionId: "sess-xyz",
                    sampled: true))
        let session = instrumentedSession()
        let exp = expectation(description: "done")
        session.dataTask(with: URL(string: "https://example.com/x")!) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 5)

        let headers = try XCTUnwrap(MockBackendURLProtocol.lastForwardedHeaders,
                                    "forwarded request headers must be observable")
        let traceparent = try XCTUnwrap(headers["traceparent"], "traceparent must be injected")
        // 00-<32 hex trace>-<16 hex span>-01
        let parts = traceparent.split(separator: "-")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "00")
        XCTAssertEqual(parts[1], "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(parts[2].count, 16, "span id must be 16 hex chars")
        XCTAssertEqual(parts[3], "01", "sampled flag")

        let baggage = try XCTUnwrap(headers["baggage"], "baggage must be injected")
        XCTAssertTrue(baggage.contains("allstak-trace_id=0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(baggage.contains("allstak-session_id=sess-xyz"))
    }

    func testInjectTraceHeadersSetIfMissingAndMergesBaggage() {
        let req = NSMutableURLRequest(url: URL(string: "https://example.com/x")!)
        // Host already set a traceparent + a vendor baggage member — both respected.
        req.setValue("00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
                     forHTTPHeaderField: "traceparent")
        req.setValue("vendor=keepme", forHTTPHeaderField: "baggage")

        AllStakURLProtocol.injectTraceHeaders(
            into: req,
            trace: HTTPInstrumentation.TraceContext(
                traceId: "0123456789abcdef0123456789abcdef", sessionId: "s1", sampled: false))

        // Host traceparent is NOT clobbered (set-if-missing).
        XCTAssertEqual(req.value(forHTTPHeaderField: "traceparent"),
                       "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01")
        // Baggage MERGES: vendor member preserved, allstak members appended.
        let baggage = req.value(forHTTPHeaderField: "baggage") ?? ""
        XCTAssertTrue(baggage.contains("vendor=keepme"), "vendor baggage preserved")
        XCTAssertTrue(baggage.contains("allstak-trace_id="), "allstak baggage appended")
        // x-allstak-trace-id added.
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-allstak-trace-id"),
                       "0123456789abcdef0123456789abcdef")
    }

    func testNoTraceContextMeansNoHeaders() throws {
        let scope = Scope()
        install(scope: scope, trace: nil) // no trace context available
        let session = instrumentedSession()
        let exp = expectation(description: "done")
        session.dataTask(with: URL(string: "https://example.com/x")!) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 5)
        let headers = MockBackendURLProtocol.lastForwardedHeaders ?? [:]
        XCTAssertNil(headers["traceparent"], "no trace context → no propagation headers")
        // But the breadcrumb is still recorded.
        XCTAssertTrue(scope.breadcrumbs.contains { $0.type == "http" })
    }

    // MARK: 4. Opt-out disables interception

    func testDisableOptsOut() {
        let scope = Scope()
        install(scope: scope)
        XCTAssertTrue(AllStakURLProtocol.canInit(
            with: URLRequest(url: URL(string: "https://example.com/x")!)))
        HTTPInstrumentation.shared.disable()
        XCTAssertFalse(AllStakURLProtocol.canInit(
            with: URLRequest(url: URL(string: "https://example.com/x")!)),
            "disabled instrumentation must decline every request (transparent pass-through)")
    }

    // MARK: 5. Network failure captured as a breadcrumb

    func testNetworkFailureCapturedAsBreadcrumb() throws {
        let scope = Scope()
        install(scope: scope)
        MockBackendURLProtocol.failWithError = true

        let session = instrumentedSession()
        let exp = expectation(description: "done")
        var capturedError: Error?
        session.dataTask(with: URL(string: "https://example.com/down")!) { _, _, err in
            capturedError = err
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)

        XCTAssertNotNil(capturedError, "the host still sees the network error (transparent relay)")
        let http = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "http" })
        XCTAssertEqual(http.level, "error", "a failed request is an error breadcrumb")
        XCTAssertTrue(http.message?.contains("failed") ?? false)
        XCTAssertNotNil(http.data?["error"], "failure breadcrumb carries an error description")
    }

    func test4xxIsErrorLevel() throws {
        let scope = Scope()
        install(scope: scope)
        MockBackendURLProtocol.nextStatus = 404
        let session = instrumentedSession()
        let exp = expectation(description: "done")
        session.dataTask(with: URL(string: "https://example.com/missing")!) { _, _, _ in exp.fulfill() }.resume()
        wait(for: [exp], timeout: 5)
        let http = try XCTUnwrap(scope.breadcrumbs.first { $0.type == "http" })
        XCTAssertEqual(http.data?["status_code"], .int(404))
        XCTAssertEqual(http.level, "error", "4xx must be error level")
    }

    // MARK: URL redaction unit (query / userinfo stripped)

    func testRedactedURLStringStripsQueryFragmentAndUserinfo() {
        let url = URL(string: "https://user:pass@example.com/p/a/th?secret=1#frag")!
        let redacted = AllStakURLProtocol.redactedURLString(url)
        XCTAssertFalse(redacted.contains("secret=1"), "query removed")
        XCTAssertFalse(redacted.contains("#frag"), "fragment removed")
        XCTAssertFalse(redacted.contains("user:pass"), "userinfo removed")
        XCTAssertTrue(redacted.contains("example.com/p/a/th"))
    }

    // MARK: Trace propagation wire-format unit (parity with allstak-js)

    func testTracePropagationWireFormatMatchesJS() {
        let v = TracePropagation.values(traceId: "abc-123", sessionId: "s", sampled: true)
        XCTAssertEqual(v.traceId.count, 32, "trace id normalized to 32 hex")
        XCTAssertEqual(v.spanId.count, 16, "span id normalized to 16 hex")
        XCTAssertTrue(v.traceparent.hasPrefix("00-\(v.traceId)-\(v.spanId)-01"))
        XCTAssertTrue(v.baggage.contains("allstak-trace_id=\(v.traceId)"))
        XCTAssertTrue(v.baggage.contains("allstak-span_id=\(v.spanId)"))
        XCTAssertTrue(v.baggage.contains("allstak-session_id=s"))

        let notSampled = TracePropagation.values(traceId: "abc", sessionId: nil, sampled: false)
        XCTAssertTrue(notSampled.traceparent.hasSuffix("-00"), "not-sampled → flag 00")
        XCTAssertFalse(notSampled.baggage.contains("session_id"), "no session id → omitted")
    }

    func testMergeBaggagePreservesVendorMembers() {
        let merged = TracePropagation.mergeBaggage(
            existing: "vendor=a, allstak-trace_id=old, other=b",
            baggage: "allstak-trace_id=new,allstak-span_id=sp")
        XCTAssertTrue(merged.contains("vendor=a"))
        XCTAssertTrue(merged.contains("other=b"))
        XCTAssertTrue(merged.contains("allstak-trace_id=new"))
        XCTAssertFalse(merged.contains("allstak-trace_id=old"), "stale allstak member dropped")
    }

    func testNormalizeIdsPadAndTruncate() {
        XCTAssertEqual(TracePropagation.normalizeTraceId("ab").count, 32)
        XCTAssertEqual(TracePropagation.normalizeSpanId("ab").count, 16)
        // A full UUID (32 hex after dash-strip) stays 32.
        let uuid = UUID().uuidString
        XCTAssertEqual(TracePropagation.normalizeTraceId(uuid).count, 32)
    }

    func testNormalizeIdsRejectAllZeroAndNonHexValues() {
        let zeroTrace = TracePropagation.normalizeTraceId(String(repeating: "0", count: 32))
        XCTAssertEqual(zeroTrace.count, 32)
        XCTAssertNotEqual(zeroTrace, String(repeating: "0", count: 32))
        XCTAssertTrue(zeroTrace.allSatisfy { $0.isHexDigit })

        let invalidSpan = TracePropagation.normalizeSpanId("not-a-span")
        XCTAssertEqual(invalidSpan.count, 16)
        XCTAssertNotEqual(invalidSpan, String(repeating: "0", count: 16))
        XCTAssertTrue(invalidSpan.allSatisfy { $0.isHexDigit })
    }
}

import XCTest
@testable import AllStak

/// Pure retry/backoff + Retry-After parsing. No network — exercises the policy
/// the reliable transport drives. Mirrors the AllStak JS SDK's parseRetryAfter +
/// jittered-backoff coverage.
final class RetryPolicyTests: XCTestCase {

    // MARK: classify(status:)

    func testClassify2xxAccepted() {
        XCTAssertEqual(RetryPolicy.classify(status: 200, retryAfter: nil), .accepted)
        XCTAssertEqual(RetryPolicy.classify(status: 202, retryAfter: nil), .accepted)
        XCTAssertEqual(RetryPolicy.classify(status: 299, retryAfter: nil), .accepted)
    }

    func testClassify401Unauthorized() {
        XCTAssertEqual(RetryPolicy.classify(status: 401, retryAfter: nil), .unauthorized)
    }

    func testClassifyNonRetryable4xxPermanent() {
        XCTAssertEqual(RetryPolicy.classify(status: 400, retryAfter: nil), .permanent)
        XCTAssertEqual(RetryPolicy.classify(status: 403, retryAfter: nil), .permanent)
        XCTAssertEqual(RetryPolicy.classify(status: 404, retryAfter: nil), .permanent)
        XCTAssertEqual(RetryPolicy.classify(status: 422, retryAfter: nil), .permanent)
    }

    func testClassify429Retryable() {
        XCTAssertEqual(RetryPolicy.classify(status: 429, retryAfter: nil),
                       .retryable(retryAfterSeconds: 0))
    }

    func testClassify429HonoursRetryAfter() {
        XCTAssertEqual(RetryPolicy.classify(status: 429, retryAfter: "12"),
                       .retryable(retryAfterSeconds: 12))
    }

    func testClassify5xxRetryable() {
        XCTAssertEqual(RetryPolicy.classify(status: 500, retryAfter: nil),
                       .retryable(retryAfterSeconds: 0))
        XCTAssertEqual(RetryPolicy.classify(status: 503, retryAfter: "30"),
                       .retryable(retryAfterSeconds: 30))
    }

    func testClassifyNetworkErrorRetryable() {
        // nil status == no HTTP response (a network/transport error).
        XCTAssertEqual(RetryPolicy.classify(status: nil, retryAfter: nil),
                       .retryable(retryAfterSeconds: 0))
    }

    // MARK: parseRetryAfter — delta-seconds

    func testRetryAfterDeltaSeconds() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("0"), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("1"), 1)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("120"), 120)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("  45  "), 45, "leading/trailing space tolerated")
    }

    func testRetryAfterCappedAtFiveMinutes() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter("999999"),
                       RetryPolicy.retryAfterCapSeconds,
                       "an absurd Retry-After is clamped to the ~300s cap")
        XCTAssertEqual(RetryPolicy.parseRetryAfter("301"), RetryPolicy.retryAfterCapSeconds)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("300"), 300, "exactly the cap is honoured")
    }

    func testRetryAfterInvalidOrAbsentReturnsZero() {
        XCTAssertEqual(RetryPolicy.parseRetryAfter(nil), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(""), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("   "), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("soon"), 0)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("-5"), 0, "negative is not a valid delta-seconds")
        XCTAssertEqual(RetryPolicy.parseRetryAfter("12.5"), 0, "fractional is not delta-seconds")
    }

    // MARK: parseRetryAfter — HTTP-date

    func testRetryAfterHttpDateInFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 60s in the future as an IMF-fixdate string.
        let future = now.addingTimeInterval(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: future)

        let seconds = RetryPolicy.parseRetryAfter(header, now: now)
        XCTAssertEqual(seconds, 60, accuracy: 1.0, "HTTP-date delta from now")
    }

    func testRetryAfterHttpDateInPastReturnsZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = "Wed, 21 Oct 2015 07:28:00 GMT" // long in the past
        XCTAssertEqual(RetryPolicy.parseRetryAfter(header, now: now), 0)
    }

    func testRetryAfterHttpDateCapped() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let farFuture = now.addingTimeInterval(10_000) // way past the 300s cap
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: farFuture)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(header, now: now),
                       RetryPolicy.retryAfterCapSeconds)
    }

    // MARK: exponential backoff + jitter

    func testBackoffIsExponentialWithFullJitterBounds() {
        // With randomUnit pinned, backoff is deterministic: base * 2^attempt is the
        // exponential ceiling; full jitter keeps the result in [exp/2, exp].
        for attempt in 0..<6 {
            let exp = min(RetryPolicy.maxBackoffSeconds,
                          RetryPolicy.baseDelaySeconds * pow(2.0, Double(attempt)))
            let lo = RetryPolicy.backoffSeconds(attempt: attempt, randomUnit: { 0.0 })
            let hi = RetryPolicy.backoffSeconds(attempt: attempt, randomUnit: { 0.999999 })
            XCTAssertEqual(lo, exp / 2, accuracy: 0.0001, "randomUnit 0 → exp/2 floor")
            XCTAssertLessThanOrEqual(hi, exp + 0.0001, "randomUnit→1 stays under exp ceiling")
            XCTAssertGreaterThanOrEqual(hi, exp / 2)
        }
    }

    func testBackoffMonotonicallyGrowsThenCaps() {
        // Mid-jitter draw so the comparison is on the exponential trend, not noise.
        let mid: () -> Double = { 0.5 }
        let b0 = RetryPolicy.backoffSeconds(attempt: 0, randomUnit: mid)
        let b1 = RetryPolicy.backoffSeconds(attempt: 1, randomUnit: mid)
        let b2 = RetryPolicy.backoffSeconds(attempt: 2, randomUnit: mid)
        XCTAssertLessThan(b0, b1)
        XCTAssertLessThan(b1, b2)
        // A very high attempt is clamped at the max backoff ceiling.
        let capped = RetryPolicy.backoffSeconds(attempt: 50, randomUnit: { 0.999999 })
        XCTAssertLessThanOrEqual(capped, RetryPolicy.maxBackoffSeconds + 0.0001)
    }
}

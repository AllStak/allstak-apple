import Foundation

/// Pure retry/backoff helpers for the reliable transport. Kept allocation-light
/// and side-effect-free so the policy can be unit-tested directly without any
/// network I/O. Mirrors the AllStak JS SDK's `parseRetryAfter` + jittered
/// exponential backoff (see allstak-js `src/transport/http.ts`).
enum RetryPolicy {

    /// Bounded number of in-process retry attempts for one delivery before the
    /// payload is handed to the persistent spool. (1 initial try + this many
    /// retries.) Matches the JS failure threshold ballpark.
    static let maxRetries = 3

    /// Base backoff before the exponential ramp, in seconds.
    static let baseDelaySeconds: Double = 0.5

    /// Hard ceiling on a single computed backoff, in seconds.
    static let maxBackoffSeconds: Double = 30

    /// Hard ceiling on an honoured `Retry-After`, in seconds (~5 min). A server
    /// asking us to wait longer than this is treated as "wait the cap".
    static let retryAfterCapSeconds: Double = 300

    /// Classification of an HTTP/transport outcome the transport acts on.
    enum Outcome: Equatable {
        /// 2xx — accepted; remove any persisted copy.
        case accepted
        /// 401 — invalid key; disable the SDK entirely.
        case unauthorized
        /// A 4xx other than 401/429 — the server will never accept this payload;
        /// drop it (and remove any persisted copy) instead of retrying forever.
        case permanent
        /// 429 / 5xx / network error — transient; retry then persist. Carries the
        /// honoured `Retry-After` delay in seconds when the server supplied one
        /// (0 → fall back to computed backoff).
        case retryable(retryAfterSeconds: Double)
    }

    /// Map an HTTP status code (and optional `Retry-After` header) to an outcome.
    /// A `nil` status means a network/transport error (no response) → retryable.
    static func classify(status: Int?, retryAfter: String?, now: Date = Date()) -> Outcome {
        guard let status else {
            return .retryable(retryAfterSeconds: 0) // network error: retry
        }
        switch status {
        case 200...299:
            return .accepted
        case 401:
            return .unauthorized
        case 429:
            return .retryable(retryAfterSeconds: parseRetryAfter(retryAfter, now: now))
        case 400...499:
            return .permanent // 4xx other than 401/429: server will never accept it
        default:
            // 5xx (and any other non-2xx, e.g. 3xx we didn't follow) → retry. A
            // 503 may carry Retry-After; honour it.
            return .retryable(retryAfterSeconds: parseRetryAfter(retryAfter, now: now))
        }
    }

    /// Jittered exponential backoff (seconds) for the given zero-based attempt.
    /// `attempt 0 → ~base`, doubling each attempt, capped at `maxBackoffSeconds`.
    /// Full jitter in `[exp/2, exp]` spreads retries from many clients (mirrors
    /// the JS `jitteredBackoff`). `randomUnit` is injectable for deterministic
    /// tests; defaults to a real uniform draw in `[0, 1)`.
    static func backoffSeconds(attempt: Int,
                               randomUnit: () -> Double = { Double.random(in: 0..<1) }) -> Double {
        let exp = min(maxBackoffSeconds, baseDelaySeconds * pow(2.0, Double(max(0, attempt))))
        let half = exp / 2
        return half + randomUnit() * half
    }

    /// Parse an HTTP `Retry-After` header into seconds, accepting either
    /// delta-seconds ("120") or an HTTP-date (RFC 7231). Clamped to
    /// `[0, retryAfterCapSeconds]`. Returns 0 when absent/invalid so the caller
    /// falls back to computed backoff. Mirrors the JS `parseRetryAfter`.
    static func parseRetryAfter(_ headerValue: String?, now: Date = Date()) -> Double {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return 0 }

        // delta-seconds: a run of ASCII digits.
        if raw.allSatisfy({ $0.isNumber }), let seconds = Double(raw) {
            return clampRetryAfter(seconds)
        }

        // HTTP-date: compute the delta from `now`.
        if let date = httpDate(raw) {
            let delta = date.timeIntervalSince(now)
            if delta <= 0 { return 0 }
            return clampRetryAfter(delta)
        }
        return 0
    }

    private static func clampRetryAfter(_ seconds: Double) -> Double {
        if seconds <= 0 { return 0 }
        return min(seconds, retryAfterCapSeconds)
    }

    /// RFC 7231 IMF-fixdate parser for the `Retry-After` HTTP-date form. Uses a
    /// fixed POSIX/en_US_POSIX formatter so locale never skews parsing.
    private static let imfFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func httpDate(_ value: String) -> Date? {
        imfFormatter.date(from: value)
    }
}

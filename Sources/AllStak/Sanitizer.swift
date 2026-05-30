import Foundation

/// Privacy / PII scrubbing primitive for the AllStak Apple SDK.
///
/// Mirrors the redaction model shipped in the sibling SDKs (notably
/// `allstak-js` `src/utils/redact.ts` and the Wave-3 value-scrubbing model):
///
///   1. **KEY denylist** — keys matched case-insensitively against a built-in
///      deny-list (`authorization`, `cookie`, `password`, `token`, `secret`,
///      `api_key`, `jwt`, `bearer`, `ssn`, `credit_card`, `cvv`, `session`, …)
///      have their value replaced with ``redactedMarker`` (`[REDACTED]`).
///   2. **VALUE patterns** scanned inside string values (value-pattern
///      data-scrubbing):
///        - ALWAYS scrubbed: Luhn-valid credit-card numbers (13–19 digits) and
///          dashed US SSNs (`\d{3}-\d{2}-\d{4}`).
///        - Scrubbed UNLESS ``sendDefaultPii`` is `true`: email addresses and
///          validated IPv4 addresses.
///   3. The walk is **recursive, cycle-safe, depth-capped, and NON-mutating** —
///      it returns fresh values and never touches caller-owned input.
///   4. **Fail-open** throughout: any internal failure returns the input value
///      unchanged so telemetry is never dropped because of a scrubber bug.
///
/// The SDK's own top-level `sessionId` is exact-key allowlisted so release-health
/// correlation is preserved even though `session` is on the key denylist.
struct Sanitizer: Sendable {

    /// The replacement written in place of a redacted value.
    static let redactedMarker = "[REDACTED]"

    /// Hard recursion ceiling — protects against hostile/cyclic-by-value input.
    static let defaultMaxDepth = 12

    /// Longest string value we scan for value-pattern PII. Longer strings are
    /// passed through unchanged so a huge/hostile string can't turn the matcher
    /// into a hot loop.
    static let maxScanLength = 16_384

    /// When `true`, the email + IPv4 value scrubbers are disabled (the caller
    /// opted into PII). The credit-card + SSN scrubbers stay on regardless.
    /// Default `false`.
    let sendDefaultPii: Bool

    let maxDepth: Int

    init(sendDefaultPii: Bool, maxDepth: Int = Sanitizer.defaultMaxDepth) {
        self.sendDefaultPii = sendDefaultPii
        self.maxDepth = max(1, maxDepth)
    }

    // MARK: Key denylist

    /// Substrings matched (case-insensitively, after lowercasing) against a key.
    /// Substring matching mirrors the sibling SDKs' boundary-aware patterns
    /// closely enough for the SDK's structured fields while staying dependency-
    /// free. Keep parity with `allstak-js` when adding entries.
    static let denylistedKeySubstrings: [String] = [
        "authorization", "proxy-authorization",
        "cookie", "set-cookie",
        "password", "passwd",
        "secret",
        "token",          // covers x-auth-token / x-access-token / accessToken …
        "api_key", "apikey", "api-key", "x-api-key",
        "x-allstak-key",
        "jwt",
        "bearer",
        "csrf",
        "ssn",
        "credit_card", "creditcard", "credit-card", "card_number", "cardnumber",
        "cvv", "cvc",
        "session",        // session / sessionId / session_id …
    ]

    /// Exact (case-insensitive) keys that must NEVER be redacted even when they
    /// would otherwise match the denylist. The SDK's own `sessionId` correlates
    /// release-health and is not user PII, so it is allowlisted past `session`.
    static let keyAllowlist: Set<String> = ["sessionid", "session_id"]

    /// `true` when a key should have its value redacted by the key denylist.
    static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if keyAllowlist.contains(lower) { return false }
        for needle in denylistedKeySubstrings where lower.contains(needle) {
            return true
        }
        return false
    }

    // MARK: Value-pattern scrubbing

    /// Scrub a single string value. Always redacts Luhn-valid credit cards and
    /// dashed SSNs; redacts emails + IPv4 unless ``sendDefaultPii``. Returns the
    /// input unchanged on any failure or for empty/oversized strings (fail-open).
    func scrubString(_ value: String) -> String {
        if value.isEmpty || value.utf16.count > Self.maxScanLength { return value }
        var out = Self.scrubCreditCards(value)
        out = Self.regexReplace(out, pattern: Self.ssnPattern, with: Self.redactedMarker)
        if !sendDefaultPii {
            out = Self.regexReplace(out, pattern: Self.emailPattern, with: Self.redactedMarker)
            out = Self.scrubIPv4(out)
        }
        return out
    }

    // ── Compiled patterns (once; `NSRegularExpression` is thread-safe) ────────

    /// US SSN — dashes REQUIRED. Bare 9-digit numbers are intentionally NOT
    /// matched (avoids nuking unrelated identifiers).
    static let ssnPattern = try? NSRegularExpression(
        pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)

    /// Conservative email: local/domain charset, dotted TLD required.
    static let emailPattern = try? NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#)

    /// Credit-card CANDIDATE run: 13–19 digits with optional single space/hyphen
    /// separators, bounded by non-digit edges. Each match is Luhn-validated
    /// before redacting; a run that fails Luhn is preserved.
    static let creditCardCandidatePattern = try? NSRegularExpression(
        pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)

    /// IPv4 CANDIDATE: four dotted groups of 1–3 digits, bounded. Octet range is
    /// validated (0–255) in code so e.g. `999.1.1.1` is not redacted.
    static let ipv4CandidatePattern = try? NSRegularExpression(
        pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)

    /// Replace every match of `regex` in `value` with `replacement`. Fail-open:
    /// returns `value` unchanged if the regex failed to compile.
    private static func regexReplace(_ value: String, pattern regex: NSRegularExpression?,
                                     with replacement: String) -> String {
        guard let regex else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: replacement)
    }

    /// Redact only Luhn-valid card candidates; non-Luhn digit runs are kept.
    private static func scrubCreditCards(_ value: String) -> String {
        guard let regex = creditCardCandidatePattern else { return value }
        let ns = value as NSString
        let matches = regex.matches(in: value, options: [],
                                    range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        // Rebuild right-to-left so earlier match ranges stay valid.
        var result = value
        for match in matches.reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            let candidate = String(result[r])
            let digits = candidate.filter { $0.isNumber }
            if digits.count >= 13 && digits.count <= 19 && passesLuhn(digits) {
                result.replaceSubrange(r, with: redactedMarker)
            }
        }
        return result
    }

    /// Redact only IPv4 candidates whose octets are all 0–255.
    private static func scrubIPv4(_ value: String) -> String {
        guard let regex = ipv4CandidatePattern else { return value }
        let ns = value as NSString
        let matches = regex.matches(in: value, options: [],
                                    range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        var result = value
        for match in matches.reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            let candidate = String(result[r])
            let octets = candidate.split(separator: ".")
            let valid = octets.count == 4 && octets.allSatisfy {
                if let n = Int($0) { return n >= 0 && n <= 255 }
                return false
            }
            if valid { result.replaceSubrange(r, with: redactedMarker) }
        }
        return result
    }

    /// Luhn checksum. `true` only for a genuine card-number candidate.
    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard let d0 = ch.wholeNumberValue, d0 >= 0, d0 <= 9 else { return false }
            var d = d0
            if alternate {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: Recursive JSONValue walk (cycle-safe, depth-capped, non-mutating)

    /// Sanitize a `JSONValue` tree. Keys matching the denylist have their value
    /// redacted; string values are value-scrubbed. Returns a fresh value tree.
    func sanitizeValue(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        if depth >= maxDepth { return .string("[MaxDepth]") }
        switch value {
        case .string(let s):
            return .string(scrubString(s))
        case .array(let arr):
            return .array(arr.map { sanitizeValue($0, depth: depth + 1) })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj {
                if Self.isSensitiveKey(k) {
                    out[k] = .string(Self.redactedMarker)
                } else {
                    out[k] = sanitizeValue(v, depth: depth + 1)
                }
            }
            return .object(out)
        case .int, .double, .bool, .null:
            return value
        }
    }

    /// Sanitize a `[String: JSONValue]` map (top-level entry point for the
    /// scope's `tags`-shaped string maps, `contexts`, and `extra`).
    func sanitizeStringValueMap(_ map: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(map.count)
        for (k, v) in map {
            if Self.isSensitiveKey(k) {
                out[k] = .string(Self.redactedMarker)
            } else {
                out[k] = sanitizeValue(v)
            }
        }
        return out
    }

    // MARK: Event sanitization (the wire chokepoint)

    /// Return a sanitized COPY of `event`. The user object, stack-frame
    /// filename/function, `release`/`sdk`/`environment` fields, `sessionId`, and
    /// `timestamp` are left untouched; `message`, breadcrumb message/data, tags,
    /// contexts, and extra are scrubbed. Fully fail-open — on any failure the
    /// caller falls back to a key-only redaction (see ``AllStakClient.send``).
    func sanitize(_ event: AllStakErrorEvent) -> AllStakErrorEvent {
        var copy = event
        copy.applyMessage(scrubString(event.message))

        if let crumbs = event.breadcrumbs {
            copy.breadcrumbs = crumbs.map { crumb in
                AllStakBreadcrumb(
                    timestamp: crumb.timestamp,
                    type: crumb.type,
                    category: crumb.category,
                    message: crumb.message.map { scrubString($0) },
                    level: crumb.level,
                    data: crumb.data.map { sanitizeStringValueMap($0) })
            }
        }

        if let tags = event.tags {
            var out: [String: String] = [:]
            for (k, v) in tags {
                out[k] = Self.isSensitiveKey(k) ? Self.redactedMarker : scrubString(v)
            }
            copy.tags = out
        }

        if let contexts = event.contexts {
            var out: [String: [String: JSONValue]] = [:]
            for (k, block) in contexts { out[k] = sanitizeStringValueMap(block) }
            copy.contexts = out
        }

        if let extra = event.extra {
            copy.extra = sanitizeStringValueMap(extra)
        }

        // `user`, `frames`, `release`, `sdkName`/`sdkVersion`, `environment`,
        // `sessionId`, `fingerprint`, `debugMeta` are deliberately preserved.
        return copy
    }

    /// Degraded fail-open path used when full sanitization fails: apply only the
    /// KEY denylist (the cheapest, most robust layer) so the highest-risk secrets
    /// are still removed even if value-pattern scrubbing blew up. Never throws in
    /// practice; `throws` only so callers can model it as a recoverable step.
    func keyOnlyRedaction(_ event: AllStakErrorEvent) throws -> AllStakErrorEvent {
        var copy = event
        if let tags = event.tags {
            var out: [String: String] = [:]
            for (k, v) in tags { out[k] = Self.isSensitiveKey(k) ? Self.redactedMarker : v }
            copy.tags = out
        }
        if let contexts = event.contexts {
            var out: [String: [String: JSONValue]] = [:]
            for (k, block) in contexts { out[k] = redactKeysOnly(block) }
            copy.contexts = out
        }
        if let extra = event.extra {
            copy.extra = redactKeysOnly(extra)
        }
        if let crumbs = event.breadcrumbs {
            copy.breadcrumbs = crumbs.map { crumb in
                AllStakBreadcrumb(
                    timestamp: crumb.timestamp, type: crumb.type, category: crumb.category,
                    message: crumb.message, level: crumb.level,
                    data: crumb.data.map { redactKeysOnly($0) })
            }
        }
        return copy
    }

    /// Recursive KEY-only redaction (no value scanning) used by the fail-open
    /// fallback. Cycle-safe via the same depth cap.
    private func redactKeysOnly(_ map: [String: JSONValue], depth: Int = 0) -> [String: JSONValue] {
        guard depth < maxDepth else { return map }
        var out: [String: JSONValue] = [:]
        for (k, v) in map {
            if Self.isSensitiveKey(k) {
                out[k] = .string(Self.redactedMarker)
            } else if case .object(let inner) = v {
                out[k] = .object(redactKeysOnly(inner, depth: depth + 1))
            } else {
                out[k] = v
            }
        }
        return out
    }
}

extension AllStakErrorEvent {
    /// `message` is a `let`, so this rebuilds the event around a new message
    /// while preserving every other field. Used by ``Sanitizer/sanitize(_:)``.
    fileprivate mutating func applyMessage(_ newMessage: String) {
        guard newMessage != message else { return }
        var rebuilt = AllStakErrorEvent(
            exceptionClass: exceptionClass,
            message: newMessage,
            level: level,
            platform: platform,
            environment: environment,
            release: release,
            sessionId: sessionId,
            frames: frames,
            debugMeta: debugMeta,
            sdkName: sdkName,
            sdkVersion: sdkVersion,
            timestamp: timestamp)
        rebuilt.breadcrumbs = breadcrumbs
        rebuilt.user = user
        rebuilt.tags = tags
        rebuilt.contexts = contexts
        rebuilt.extra = extra
        rebuilt.fingerprint = fingerprint
        self = rebuilt
    }
}

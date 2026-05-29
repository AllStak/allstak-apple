import Foundation

/// W3C distributed-tracing wire format — the Apple-side mirror of
/// `allstak-js/src/modules/trace-propagation.ts`, so an iOS → backend →
/// downstream chain shares one trace with byte-identical header semantics.
///
/// Header shape produced (set-if-missing by the caller, baggage merged):
///   * `traceparent: 00-<32-hex traceId>-<16-hex spanId>-<flags>`
///     where flags is `01` (sampled) or `00` (not sampled).
///   * `baggage: allstak-trace_id=<traceId>,allstak-span_id=<spanId>[,allstak-session_id=<sessionId>]`
///   * `x-allstak-trace-id: <normalized traceId>`
///
/// The span id is freshly minted per outbound request (each request is a child
/// span of the head-of-trace). Pure value types; no I/O, no global state.
enum TracePropagation {

    struct Values {
        let traceparent: String
        let baggage: String
        let traceId: String   // normalized, 32 hex
        let spanId: String    // normalized, 16 hex
    }

    /// Normalize a trace id to 32 lower-case hex chars (dashes stripped, padded /
    /// truncated). Matches `normalizeTraceId` in the JS SDK.
    static func normalizeTraceId(_ traceId: String) -> String {
        normalizeHex(traceId, width: 32)
    }

    /// Normalize a span id to 16 lower-case hex chars. Matches `normalizeSpanId`.
    static func normalizeSpanId(_ spanId: String) -> String {
        normalizeHex(spanId, width: 16)
    }

    /// Lower-case, strip dashes, keep only hex digits, truncate to `width`, then
    /// right-pad with `0`. Non-hex characters are dropped (so a UUID with dashes
    /// becomes its hex run) — defensive parity with the JS `replace(/-/g,'')`
    /// approach, hardened against stray non-hex input.
    private static func normalizeHex(_ value: String, width: Int) -> String {
        let hex = value.lowercased().filter { $0.isHexDigit }
        let truncated = String(hex.prefix(width))
        if truncated.count >= width { return truncated }
        return truncated + String(repeating: "0", count: width - truncated.count)
    }

    /// Compute the propagation header values for a trace. A fresh span id is
    /// generated per call (a new child span for this outbound request).
    static func values(traceId: String, sessionId: String?, sampled: Bool) -> Values {
        let normTrace = normalizeTraceId(traceId)
        let spanId = normalizeSpanId(UUID().uuidString)
        let flag = sampled ? "01" : "00"
        let traceparent = "00-\(normTrace)-\(spanId)-\(flag)"
        var members = [
            "allstak-trace_id=\(percentEncode(normTrace))",
            "allstak-span_id=\(percentEncode(spanId))",
        ]
        if let sessionId, !sessionId.isEmpty {
            members.append("allstak-session_id=\(percentEncode(sessionId))")
        }
        return Values(traceparent: traceparent,
                      baggage: members.joined(separator: ","),
                      traceId: normTrace,
                      spanId: spanId)
    }

    /// Merge AllStak baggage members into an existing `baggage` string, preserving
    /// any non-`allstak-` (vendor) members. Mirrors `mergeBaggageValue` in the JS
    /// SDK so a shared request doesn't clobber upstream vendor baggage.
    static func mergeBaggage(existing: String, baggage: String) -> String {
        let preserved = existing
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("allstak-") }
        return (preserved + baggage.split(separator: ",").map(String.init))
            .joined(separator: ",")
    }

    /// Conservative percent-encoding for a baggage member value (parity with the
    /// JS `encodeURIComponent`; our ids are hex/UUID so this is rarely needed).
    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

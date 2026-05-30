import XCTest
@testable import AllStak

/// PII scrubbing + `beforeSend`. Mirrors the cross-SDK redaction model
/// (`allstak-js` `src/utils/redact.ts` + the Wave-3 value-scrubbing model):
/// key denylist, Luhn-validated credit cards, dashed SSNs (always), email + IPv4
/// gated by `sendDefaultPii`, the explicit user object never value-scrubbed, the
/// SDK's own `sessionId` allowlisted, and the `beforeSend` drop/mutate hook +
/// fail-open behaviour at the wire chokepoint.
final class SanitizerTests: XCTestCase {

    private let R = Sanitizer.redactedMarker

    private func client(sendDefaultPii: Bool = false,
                        beforeSend: (@Sendable (AllStakErrorEvent) -> AllStakErrorEvent?)? = nil)
        -> AllStakClient {
        AllStakClient(apiKey: "k", host: "https://h.test", environment: "test",
                      release: "1.0.0", sendDefaultPii: sendDefaultPii, beforeSend: beforeSend)
    }

    // MARK: (A) KEY denylist

    func testKeyDenylistRedactsValues() {
        let s = Sanitizer(sendDefaultPii: false)
        for key in ["authorization", "Cookie", "password", "api_key", "apiKey",
                    "x-api-key", "secret", "accessToken", "auth_token", "jwt",
                    "Bearer", "csrf", "ssn", "credit_card", "cvv", "session"] {
            let out = s.sanitizeStringValueMap([key: .string("hunter2")])
            XCTAssertEqual(out[key], .string(R), "key '\(key)' must be redacted")
        }
    }

    func testNonSensitiveKeysPreserved() {
        let s = Sanitizer(sendDefaultPii: false)
        let out = s.sanitizeStringValueMap([
            "topic": .string("not-a-token"),   // must NOT match *token loosely-bad
            "username": .string("alice"),
            "count": .int(3),
        ])
        XCTAssertEqual(out["topic"], .string("not-a-token"))
        XCTAssertEqual(out["username"], .string("alice"))
        XCTAssertEqual(out["count"], .int(3))
    }

    func testNestedKeyDenylistRedactsRecursively() {
        let s = Sanitizer(sendDefaultPii: false)
        let nested: JSONValue = .object([
            "outer": .object([
                "password": .string("p"),
                "ok": .string("keep"),
            ]),
        ])
        guard case .object(let top) = s.sanitizeValue(nested),
              case .object(let inner) = top["outer"] else {
            return XCTFail("expected nested object")
        }
        XCTAssertEqual(inner["password"], .string(R))
        XCTAssertEqual(inner["ok"], .string("keep"))
    }

    // MARK: sessionId allowlist (exact-key, past the `session` denylist entry)

    func testSessionIdKeyAllowlisted() {
        XCTAssertFalse(Sanitizer.isSensitiveKey("sessionId"))
        XCTAssertFalse(Sanitizer.isSensitiveKey("session_id"))
        // But a bare `session` key is still sensitive.
        XCTAssertTrue(Sanitizer.isSensitiveKey("session"))
        XCTAssertTrue(Sanitizer.isSensitiveKey("user_session"))
    }

    func testTopLevelSessionIdNeverScrubbed() throws {
        let c = client()
        let base = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        // Inject a sessionId as if the tracker had stamped one (under XCTest the
        // tracker is auto-suppressed, so we build the event with one explicitly).
        let event = AllStakErrorEvent(
            exceptionClass: base.exceptionClass, message: base.message, level: base.level,
            platform: base.platform, environment: base.environment, release: base.release,
            sessionId: "sess-abc-123", frames: base.frames, debugMeta: base.debugMeta,
            sdkName: base.sdkName, sdkVersion: base.sdkVersion, timestamp: base.timestamp)
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.sessionId, "sess-abc-123",
                       "the SDK's own sessionId must survive scrubbing")
    }

    // MARK: (B) VALUE patterns — credit card (Luhn)

    func testCreditCardLuhnValidRedacted() {
        let s = Sanitizer(sendDefaultPii: false)
        // 4242 4242 4242 4242 is a Luhn-valid Visa test number.
        XCTAssertEqual(s.scrubString("card 4242424242424242 here"), "card \(R) here")
        XCTAssertEqual(s.scrubString("card 4242 4242 4242 4242 here"), "card \(R) here")
        XCTAssertEqual(s.scrubString("card 4242-4242-4242-4242 here"), "card \(R) here")
    }

    func testCreditCardLuhnInvalidPreserved() {
        let s = Sanitizer(sendDefaultPii: false)
        // 1234567812345678 fails Luhn → must be preserved (order ids etc.).
        XCTAssertEqual(s.scrubString("ref 1234567812345678 end"), "ref 1234567812345678 end")
    }

    func testCreditCardScrubbedEvenWhenSendDefaultPiiTrue() {
        // Financial data is ALWAYS scrubbed regardless of sendDefaultPii.
        let s = Sanitizer(sendDefaultPii: true)
        XCTAssertEqual(s.scrubString("4242424242424242"), R)
    }

    func testLuhnHelper() {
        XCTAssertTrue(Sanitizer.passesLuhn("4242424242424242"))
        XCTAssertFalse(Sanitizer.passesLuhn("1234567812345678"))
    }

    // MARK: (B) VALUE patterns — SSN (always)

    func testSSNAlwaysRedacted() {
        XCTAssertEqual(Sanitizer(sendDefaultPii: false).scrubString("ssn 123-45-6789 x"),
                       "ssn \(R) x")
        // Even with sendDefaultPii true, dashed SSNs are always scrubbed.
        XCTAssertEqual(Sanitizer(sendDefaultPii: true).scrubString("ssn 123-45-6789 x"),
                       "ssn \(R) x")
    }

    func testBareNineDigitsNotTreatedAsSSN() {
        // Hyphens are required; a bare 9-digit number is preserved.
        XCTAssertEqual(Sanitizer(sendDefaultPii: false).scrubString("id 123456789 x"),
                       "id 123456789 x")
    }

    // MARK: (B) VALUE patterns — email + IPv4 gated by sendDefaultPii

    func testEmailAndIPRedactedWhenSendDefaultPiiFalse() {
        let s = Sanitizer(sendDefaultPii: false)
        XCTAssertEqual(s.scrubString("mail alice@example.com now"), "mail \(R) now")
        XCTAssertEqual(s.scrubString("from 192.168.1.100 ok"), "from \(R) ok")
    }

    func testEmailAndIPPreservedWhenSendDefaultPiiTrue() {
        let s = Sanitizer(sendDefaultPii: true)
        XCTAssertEqual(s.scrubString("mail alice@example.com now"), "mail alice@example.com now")
        XCTAssertEqual(s.scrubString("from 192.168.1.100 ok"), "from 192.168.1.100 ok")
    }

    func testInvalidIPv4OctetsPreserved() {
        // 999.1.1.1 is not a valid IPv4 (octet > 255) → preserved.
        let s = Sanitizer(sendDefaultPii: false)
        XCTAssertEqual(s.scrubString("bad 999.1.1.1 here"), "bad 999.1.1.1 here")
    }

    // MARK: explicit user object NOT scrubbed

    func testExplicitUserNotScrubbed() {
        let c = client(sendDefaultPii: false)
        c.setUser(id: "u1", email: "alice@example.com", ip: "192.168.1.100")
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.user?.id, "u1")
        XCTAssertEqual(scrubbed.user?.email, "alice@example.com",
                       "the explicit user email must NOT be value-scrubbed")
        XCTAssertEqual(scrubbed.user?.ip, "192.168.1.100",
                       "the explicit user ip must NOT be value-scrubbed")
    }

    func testStackFrameAndReleaseFieldsNotScrubbed() {
        let c = client(sendDefaultPii: false)
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.release, "1.0.0", "release must survive scrubbing")
        XCTAssertEqual(scrubbed.sdkName, AllStakClient.sdkName)
        XCTAssertEqual(scrubbed.frames.count, event.frames.count)
        XCTAssertEqual(scrubbed.frames.first?.instructionAddr, event.frames.first?.instructionAddr,
                       "frame instruction addresses must survive scrubbing")
    }

    // MARK: message + breadcrumb + tags/contexts/extra scrubbing

    func testMessageScrubbed() {
        let c = client(sendDefaultPii: false)
        let event = c.buildEvent(exceptionClass: "E",
                                 message: "card 4242424242424242 ssn 123-45-6789",
                                 level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.message, "card \(R) ssn \(R)")
    }

    func testBreadcrumbMessageAndDataScrubbed() {
        let c = client(sendDefaultPii: false)
        c.addBreadcrumb(type: "http", message: "login alice@example.com",
                        category: "auth", level: "info",
                        data: ["password": "p", "note": "ip 10.0.0.1"])
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        let crumb = scrubbed.breadcrumbs?.first
        XCTAssertEqual(crumb?.message, "login \(R)", "breadcrumb message value-scrubbed")
        XCTAssertEqual(crumb?.data?["password"], .string(R), "breadcrumb data key-redacted")
        XCTAssertEqual(crumb?.data?["note"], .string("ip \(R)"), "breadcrumb data value-scrubbed")
    }

    func testTagsContextsExtraScrubbed() {
        let c = client(sendDefaultPii: false)
        c.setTag("token", "abc")                    // sensitive key
        c.setTag("note", "mail bob@x.io")           // value-scrubbed
        c.setContext("auth", ["secret": "s", "host": "1.2.3.4"])
        c.setExtra("password", "p")
        c.setExtra("free", "card 4242424242424242")
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.tags?["token"], R)
        XCTAssertEqual(scrubbed.tags?["note"], "mail \(R)")
        XCTAssertEqual(scrubbed.contexts?["auth"]?["secret"], .string(R))
        XCTAssertEqual(scrubbed.contexts?["auth"]?["host"], .string(R))   // IPv4 scrubbed
        XCTAssertEqual(scrubbed.extra?["password"], .string(R))
        XCTAssertEqual(scrubbed.extra?["free"], .string("card \(R)"))
    }

    // MARK: non-mutating

    func testSanitizeDoesNotMutateInput() {
        let c = client(sendDefaultPii: false)
        c.setExtra("password", "p")
        let event = c.buildEvent(exceptionClass: "E",
                                 message: "card 4242424242424242", level: "error", addresses: [0x1])
        _ = c.sanitizedForWire(event)
        // The original event object is unchanged (value semantics + non-mutating walk).
        XCTAssertEqual(event.message, "card 4242424242424242")
        XCTAssertEqual(event.extra?["password"], .string("p"))
    }

    // MARK: cycle/depth safety

    func testDepthCapStopsDeepRecursion() {
        let s = Sanitizer(sendDefaultPii: false, maxDepth: 2)
        let deep: JSONValue = .object(["a": .object(["b": .object(["c": .string("x")])])])
        // At depth >= 2 the walk short-circuits to a marker rather than recursing
        // forever / blowing the stack.
        let out = s.sanitizeValue(deep)
        let encoded = String(data: try! JSONEncoder().encode(out), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("[MaxDepth]"), "depth cap must bound recursion")
    }

    // MARK: beforeSend — drop + mutate

    func testBeforeSendDropReturnsNilProducesNoBody() {
        // Returning nil from beforeSend drops the event; sanitizedForWire is never
        // reached. We can only assert the hook is honoured indirectly via a flag.
        let dropped = LockedFlag()
        let c = client(beforeSend: { _ in dropped.set(); return nil })
        // capture(message:) routes through send(); the drop is observed by the flag.
        c.capture(message: "drop me", level: "error")
        XCTAssertTrue(dropped.value, "beforeSend must run before send")
    }

    func testBeforeSendReceivesSanitizedEventAndCannotReintroduceSecrets() throws {
        let seen = LockedEvent()
        let c = client(beforeSend: { ev in
            seen.set(ev)
            var copy = AllStakErrorEvent(
                exceptionClass: ev.exceptionClass, message: "mutated 5555555555554444",
                level: ev.level, platform: ev.platform, environment: ev.environment,
                release: ev.release, sessionId: ev.sessionId, frames: ev.frames,
                debugMeta: ev.debugMeta, sdkName: ev.sdkName, sdkVersion: ev.sdkVersion,
                timestamp: ev.timestamp,
                extra: ["token": .string("secret-token")])
            copy.tags = ["env": "prod"]
            return copy
        })
        var original = AllStakErrorEvent(
            exceptionClass: "E", message: "card 4242424242424242", level: "error",
            platform: "cocoa", environment: nil, release: nil, sessionId: nil,
            frames: [], debugMeta: AllStakDebugMeta(images: []),
            sdkName: "x", sdkVersion: "y", timestamp: 0)
        original.extra = ["Authorization": .string("Bearer abc")]

        let body = try XCTUnwrap(c.scrubbedBody(original))
        let wire = try JSONDecoder().decode(AllStakErrorEvent.self, from: body)

        XCTAssertEqual(seen.value?.message, "card \(R)")
        XCTAssertEqual(seen.value?.extra?["Authorization"], .string(R))
        XCTAssertEqual(wire.message, "mutated \(R)")
        XCTAssertEqual(wire.extra?["token"], .string(R))
        XCTAssertEqual(wire.tags?["env"], "prod")
    }

    // MARK: fail-open

    func testFailOpenKeyOnlyRedactionStillRemovesSecrets() throws {
        // The degraded fallback path must still strip the highest-risk keys.
        let s = Sanitizer(sendDefaultPii: false)
        let event = AllStakErrorEvent(
            exceptionClass: "E", message: "m", level: "error", platform: "cocoa",
            environment: nil, release: nil, sessionId: nil, frames: [],
            debugMeta: AllStakDebugMeta(images: []), sdkName: "x", sdkVersion: "y", timestamp: 0,
            tags: ["password": "p", "ok": "keep"],
            extra: ["secret": .string("s"), "free": .string("untouched")])
        let degraded = try s.keyOnlyRedaction(event)
        XCTAssertEqual(degraded.tags?["password"], R)
        XCTAssertEqual(degraded.tags?["ok"], "keep")
        XCTAssertEqual(degraded.extra?["secret"], .string(R))
        // Value-scrubbing is intentionally skipped in the degraded path, so
        // non-key data is left as-is rather than dropped.
        XCTAssertEqual(degraded.extra?["free"], .string("untouched"))
    }

    func testSanitizedForWireNeverDropsTelemetry() {
        // Even for pathological input, sanitizedForWire returns a usable event
        // (never nil / never throws into the caller) so telemetry is not lost.
        let c = client(sendDefaultPii: false)
        c.setExtra("blob", String(repeating: "4242424242424242 ", count: 5000))
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let scrubbed = c.sanitizedForWire(event)
        XCTAssertEqual(scrubbed.exceptionClass, "E")
        XCTAssertNotNil(scrubbed.extra?["blob"])
    }
}

/// Tiny thread-safe boolean used to observe that a fire-and-forget callback ran.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    func set() { lock.lock(); _v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _v }
}

private final class LockedEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AllStakErrorEvent?
    func set(_ value: AllStakErrorEvent) { lock.lock(); _value = value; lock.unlock() }
    var value: AllStakErrorEvent? { lock.lock(); defer { lock.unlock() }; return _value }
}

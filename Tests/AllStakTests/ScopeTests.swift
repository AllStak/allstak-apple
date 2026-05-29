import XCTest
@testable import AllStak

/// Sentry-cocoa-style scope: breadcrumb ring buffer (cap + FIFO), user / tags /
/// context attach to events, `withScope` isolation, JSON omit-when-empty so the
/// existing wire shape is preserved, and Codable round-trips for the scope-bearing
/// `AllStakErrorEvent` (incl. the `JSONValue` helper).
final class ScopeTests: XCTestCase {

    private func client() -> AllStakClient {
        // Under XCTest the session tracker is auto-suppressed, so events carry no
        // sessionId and we can assert on scope fields in isolation.
        AllStakClient(apiKey: "k", host: "https://h.test",
                      environment: "test", release: "1.0.0")
    }

    // MARK: Breadcrumb ring buffer (cap + FIFO)

    func testBreadcrumbRingBufferCapAndFIFO() {
        let scope = Scope(maxBreadcrumbs: 3)
        for i in 0..<5 {
            scope.addBreadcrumb(type: "info", message: "m\(i)")
        }
        let crumbs = scope.breadcrumbs
        XCTAssertEqual(crumbs.count, 3, "buffer must be capped at maxBreadcrumbs")
        // Oldest (m0, m1) dropped; newest three kept in order.
        XCTAssertEqual(crumbs.map(\.message), ["m2", "m3", "m4"],
                       "ring buffer must drop oldest first (FIFO)")
    }

    func testBreadcrumbDefaultCapIs100() {
        let scope = Scope()
        for i in 0..<150 { scope.addBreadcrumb(type: "info", message: "m\(i)") }
        XCTAssertEqual(scope.breadcrumbs.count, Scope.defaultMaxBreadcrumbs)
        XCTAssertEqual(scope.breadcrumbs.count, 100)
        XCTAssertEqual(scope.breadcrumbs.first?.message, "m50", "oldest 50 dropped")
        XCTAssertEqual(scope.breadcrumbs.last?.message, "m149")
    }

    func testBreadcrumbZeroCapDisables() {
        let scope = Scope(maxBreadcrumbs: 0)
        scope.addBreadcrumb(type: "info", message: "x")
        XCTAssertTrue(scope.breadcrumbs.isEmpty, "cap 0 disables breadcrumbs")
    }

    func testUnknownBreadcrumbTypeNormalisedToDefault() {
        let scope = Scope()
        scope.addBreadcrumb(type: "totally-bogus", message: "x")
        XCTAssertEqual(scope.breadcrumbs.first?.type, "default")
        scope.addBreadcrumb(type: "navigation", message: "y")
        XCTAssertEqual(scope.breadcrumbs.last?.type, "navigation", "valid types kept")
    }

    // MARK: setUser / tags / context attach to events

    func testUserAttachesToEvent() {
        let c = client()
        c.setUser(id: "u1", email: "a@b.com", ip: "1.2.3.4")
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertEqual(event.user?.id, "u1")
        XCTAssertEqual(event.user?.email, "a@b.com")
        XCTAssertEqual(event.user?.ip, "1.2.3.4")
    }

    func testClearUserRemovesUserFromEvent() {
        let c = client()
        c.setUser(id: "u1")
        c.clearUser()
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertNil(event.user, "cleared user must not be attached")
    }

    func testTagsAttachToEvent() {
        let c = client()
        c.setTag("screen", "home")
        c.setTags(["build": "123", "tier": "free"])
        c.removeTag("tier")
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertEqual(event.tags?["screen"], "home")
        XCTAssertEqual(event.tags?["build"], "123")
        XCTAssertNil(event.tags?["tier"], "removed tag must be gone")
    }

    func testContextAndExtraAttachToEvent() throws {
        let c = client()
        c.setContext("device", ["model": "iPhone15,2", "rooted": false, "battery": 87])
        c.setExtra("attempt", 3)
        c.setExtras(["feature_flag": "x", "ratio": 0.5])
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])

        XCTAssertEqual(event.contexts?["device"]?["model"], .string("iPhone15,2"))
        XCTAssertEqual(event.contexts?["device"]?["rooted"], .bool(false))
        XCTAssertEqual(event.contexts?["device"]?["battery"], .int(87))
        XCTAssertEqual(event.extra?["attempt"], .int(3))
        XCTAssertEqual(event.extra?["feature_flag"], .string("x"))
        XCTAssertEqual(event.extra?["ratio"], .double(0.5))
    }

    func testBreadcrumbsAttachToEvent() {
        let c = client()
        c.addBreadcrumb(type: "navigation", message: "open settings",
                        category: "ui", level: "info", data: ["from": "home"])
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertEqual(event.breadcrumbs?.count, 1)
        let crumb = event.breadcrumbs?.first
        XCTAssertEqual(crumb?.type, "navigation")
        XCTAssertEqual(crumb?.category, "ui")
        XCTAssertEqual(crumb?.message, "open settings")
        XCTAssertEqual(crumb?.data?["from"], .string("home"))
        XCTAssertFalse(crumb?.timestamp.isEmpty ?? true, "breadcrumb timestamp must be set")
    }

    func testScopeLevelOverridesEventLevel() {
        let c = client()
        c.configureScope { $0.setLevel("fatal") }
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertEqual(event.level, "fatal", "scope level override must win over call-site level")
    }

    // MARK: withScope isolation

    func testWithScopeDoesNotLeakIntoGlobalScope() {
        let c = client()
        c.setTag("env", "prod")
        c.withScope { local in
            local.setTag(key: "transient", value: "yes")
            let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
            // Inside: global tag is inherited by the clone, plus the transient one.
            XCTAssertEqual(event.tags?["env"], "prod")
            XCTAssertEqual(event.tags?["transient"], "yes")
        }
        // Outside: the transient tag must not have leaked into the global scope.
        let after = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertEqual(after.tags?["env"], "prod")
        XCTAssertNil(after.tags?["transient"], "withScope mutations must not leak to global scope")
    }

    func testWithScopePopsEvenWhenBodyThrows() {
        let c = client()
        struct Boom: Error {}
        XCTAssertThrowsError(try c.withScope { local in
            local.setTag(key: "transient", value: "yes")
            throw Boom()
        })
        // After a throwing body the override scope is popped, so a later capture
        // uses the (unchanged) global scope.
        XCTAssertNil(c.activeOverrideScope, "throwing withScope must still pop the override")
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        XCTAssertNil(event.tags?["transient"])
    }

    func testNestedWithScopeInnermostWins() {
        let c = client()
        c.withScope { outer in
            outer.setTag(key: "layer", value: "outer")
            c.withScope { inner in
                inner.setTag(key: "layer", value: "inner")
                let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
                XCTAssertEqual(event.tags?["layer"], "inner")
            }
            // Back to the outer override after the inner pops.
            let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
            XCTAssertEqual(event.tags?["layer"], "outer")
        }
    }

    // MARK: JSON omits empties (existing wire shape preserved when scope unused)

    func testJSONOmitsScopeFieldsWhenEmpty() throws {
        let c = client()
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let json = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        for field in ["breadcrumbs", "user", "tags", "contexts", "metadata", "fingerprint"] {
            XCTAssertFalse(json.contains("\"\(field)\""),
                           "empty scope field \(field) must be omitted from JSON")
        }
        // The pre-scope wire shape is intact.
        XCTAssertTrue(json.contains("\"exceptionClass\""))
        XCTAssertTrue(json.contains("\"debugMeta\""))
        XCTAssertTrue(json.contains("\"cocoa\""))
    }

    func testJSONIncludesScopeFieldsWhenSet() throws {
        let c = client()
        c.setUser(id: "u1")
        c.setTag("k", "v")
        c.setContext("device", ["model": "x"])
        c.setExtra("e", 1)
        c.addBreadcrumb(type: "info", message: "hi")
        let json = String(data: try JSONEncoder().encode(
            c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])),
            encoding: .utf8)!
        XCTAssertTrue(json.contains("\"breadcrumbs\""))
        XCTAssertTrue(json.contains("\"user\""))
        XCTAssertTrue(json.contains("\"tags\""))
        XCTAssertTrue(json.contains("\"contexts\""))
        // `extra` is wired under the backend `metadata` field.
        XCTAssertTrue(json.contains("\"metadata\""))
        // `username` is SDK-side only and must NOT be on the wire.
        c.setUser(id: "u1", username: "secret")
        let json2 = String(data: try JSONEncoder().encode(
            c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])),
            encoding: .utf8)!
        XCTAssertFalse(json2.contains("secret"), "username must not cross the wire")
    }

    // MARK: Codable round-trips

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "s": .string("x"),
            "i": .int(7),
            "d": .double(1.5),
            "b": .bool(true),
            "n": .null,
            "arr": .array([.int(1), .string("two")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testJSONValueFromAnyCoercesTypes() {
        XCTAssertEqual(JSONValue("hi"), .string("hi"))
        XCTAssertEqual(JSONValue(42), .int(42))
        XCTAssertEqual(JSONValue(true), .bool(true))
        XCTAssertEqual(JSONValue(nil), .null)
        XCTAssertEqual(JSONValue(NSNull()), .null)
        // A non-JSON type is coerced to its description (fail-open), not dropped.
        if case .string = JSONValue(Date()) {} else {
            XCTFail("non-JSON value should coerce to a string")
        }
    }

    func testEventCodableRoundTripWithScope() throws {
        let c = client()
        c.setUser(id: "u1", email: "a@b.com", ip: "9.9.9.9")
        c.setTag("screen", "home")
        c.setContext("device", ["model": "iPhone", "n": 12])
        c.setExtra("flag", true)
        c.addBreadcrumb(type: "http", message: "GET /x -> 200",
                        category: "fetch", level: "info", data: ["status": 200])

        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AllStakErrorEvent.self, from: data)

        XCTAssertEqual(decoded.user?.id, "u1")
        XCTAssertEqual(decoded.user?.email, "a@b.com")
        XCTAssertEqual(decoded.tags?["screen"], "home")
        XCTAssertEqual(decoded.contexts?["device"]?["model"], .string("iPhone"))
        XCTAssertEqual(decoded.contexts?["device"]?["n"], .int(12))
        XCTAssertEqual(decoded.extra?["flag"], .bool(true))
        XCTAssertEqual(decoded.breadcrumbs?.count, 1)
        XCTAssertEqual(decoded.breadcrumbs?.first?.type, "http")
        XCTAssertEqual(decoded.breadcrumbs?.first?.category, "fetch")
        XCTAssertEqual(decoded.breadcrumbs?.first?.data?["status"], .int(200))
    }

    func testEmptyEventRoundTripKeepsScopeNil() throws {
        // An event with no scope must decode back with nil scope fields, so the
        // omit-when-empty contract round-trips cleanly.
        let c = client()
        let event = c.buildEvent(exceptionClass: "E", message: "m", level: "error", addresses: [0x1])
        let decoded = try JSONDecoder().decode(
            AllStakErrorEvent.self, from: try JSONEncoder().encode(event))
        XCTAssertNil(decoded.breadcrumbs)
        XCTAssertNil(decoded.user)
        XCTAssertNil(decoded.tags)
        XCTAssertNil(decoded.contexts)
        XCTAssertNil(decoded.extra)
    }

    // MARK: crash events carry the global scope

    func testCrashEventCarriesGlobalScope() {
        let c = client()
        c.setUser(id: "u-crash")
        c.addBreadcrumb(type: "ui", message: "tapped")
        let report = CrashReport(kind: "signal", name: "SIGSEGV", message: "boom",
                                 addresses: [0x1, 0x2], timestamp: 1_700_000_000)
        let event = c.buildCrashEvent(report, images: [])
        XCTAssertEqual(event.user?.id, "u-crash")
        XCTAssertEqual(event.breadcrumbs?.first?.message, "tapped")
        XCTAssertEqual(event.level, "fatal")
    }
}

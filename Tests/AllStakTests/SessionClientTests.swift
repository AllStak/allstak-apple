import XCTest
@testable import AllStak

/// Client-level session wiring: the `enableAutoSessionTracking` opt-out, the
/// XCTest auto-skip guard, the crash-aware open-session marker, and that the
/// session id is stamped on / omitted from the error envelope appropriately.
final class SessionClientTests: XCTestCase {

    private func tempStore() -> CrashStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-session-test-" + UUID().uuidString)
        return CrashStore(directory: dir)
    }

    // MARK: enableAutoSessionTracking opt-out

    func testOptOutDisablesTracker() {
        let client = AllStakClient(apiKey: "k", host: "https://h.test",
                                   environment: "test", release: "1.0.0",
                                   enableAutoSessionTracking: false)
        XCTAssertNil(client.sessionTracker, "opt-out must produce no session tracker")
    }

    func testTrackerSuppressedUnderXCTestEvenWhenEnabled() {
        // We ARE running under XCTest, so the unit-test guard must suppress the
        // tracker even with auto session tracking left at its default (true).
        let client = AllStakClient(apiKey: "k", host: "https://h.test",
                                   environment: "test", release: "1.0.0",
                                   enableAutoSessionTracking: true)
        XCTAssertNil(client.sessionTracker,
                     "session tracking must auto-skip under the test runtime")
    }

    // MARK: sessionId on the event envelope

    func testEventOmitsSessionIdWhenTrackingDisabled() throws {
        // Under XCTest the tracker is nil, so sessionId resolves to nil and the
        // encoder drops the optional field — preserving the existing wire shape.
        let client = AllStakClient(apiKey: "k", host: "https://h.test",
                                   environment: "test", release: "1.0.0")
        let event = client.buildEvent(exceptionClass: "E", message: "m",
                                       level: "error", addresses: [0x1])
        XCTAssertNil(event.sessionId)
        let json = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"sessionId\""),
                       "nil sessionId must be omitted from the JSON body")
    }

    func testEventCarriesSessionIdWhenTrackerActive() throws {
        // Build a tracker directly (the client guards it under XCTest) and assert
        // the model field is stamped + encodes to camelCase JSON for the backend.
        let event = AllStakErrorEvent(
            exceptionClass: "E", message: "m", level: "error", platform: "cocoa",
            environment: "test", release: "1.0.0", sessionId: "sess-123",
            frames: [], debugMeta: AllStakDebugMeta(images: []),
            sdkName: "allstak-apple", sdkVersion: "0.1.0",
            timestamp: 1_700_000_000)
        XCTAssertEqual(event.sessionId, "sess-123")
        let json = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"sessionId\":\"sess-123\""))
    }

    // MARK: crash-aware open-session marker (next-launch reconciliation source)

    func testOpenSessionMarkerRoundTrip() {
        let store = tempStore()
        XCTAssertNil(store.openSession())

        store.writeOpenSession(OpenSessionMarker(
            sessionId: "s1", startedAt: 1_700_000_000, status: "ok"))
        let marker = store.openSession()
        XCTAssertEqual(marker?.sessionId, "s1")
        XCTAssertEqual(marker?.status, "ok")

        store.clearOpenSession()
        XCTAssertNil(store.openSession(), "graceful end clears the marker")
    }

    func testMarkOpenSessionUpgradesStatusToCrashed() {
        let store = tempStore()
        store.writeOpenSession(OpenSessionMarker(
            sessionId: "s2", startedAt: 1_700_000_000, status: "ok"))
        store.markOpenSession(status: "crashed")
        XCTAssertEqual(store.openSession()?.status, "crashed")
        XCTAssertEqual(store.openSession()?.sessionId, "s2", "id must be preserved")
    }

    func testMarkOpenSessionNoOpWhenNoMarker() {
        let store = tempStore()
        store.markOpenSession(status: "crashed")
        XCTAssertNil(store.openSession(), "marking with no marker present is a no-op")
    }
}

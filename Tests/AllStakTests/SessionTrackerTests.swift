import XCTest
@testable import AllStak

/// Release-health session lifecycle: start payload shape, end payload shape +
/// status transitions (ok → errored → crashed), idempotency, the never-sampled
/// behaviour, and the transport-disabled guard. The tracker takes an injected
/// `sender` seam so payloads are asserted without any network I/O.
final class SessionTrackerTests: XCTestCase {

    /// Captures every `(path, body)` the tracker tries to send.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(path: String, body: [String: Any?])] = []
        func record(_ path: String, _ body: [String: Any?]) {
            lock.lock(); _sent.append((path, body)); lock.unlock()
        }
        var sent: [(path: String, body: [String: Any?])] {
            lock.lock(); defer { lock.unlock() }; return _sent
        }
    }

    private final class MemoryStore: SessionStateStore {
        private let lock = NSLock()
        private var state: [String: Any]?
        init(_ initial: [String: Any]? = nil) {
            self.state = initial
        }
        func read() -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return state
        }
        func write(_ state: [String: Any]) {
            lock.lock(); self.state = state; lock.unlock()
        }
        func clear() {
            lock.lock(); state = nil; lock.unlock()
        }
    }

    private func makeTracker(transportEnabled: Bool = true,
                             store: SessionStateStore? = nil,
                             recorder: Recorder) -> SessionTracker {
        SessionTracker(
            release: "1.2.3",
            environment: "production",
            sdkName: "allstak-apple",
            sdkVersion: "0.1.0",
            platform: "cocoa",
            transportEnabled: transportEnabled,
            stateStore: store,
            sender: { path, body in recorder.record(path, body) })
    }

    // MARK: start payload shape

    func testStartPostsStartEnvelopeWithExpectedFields() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)

        let session = tracker.start(userId: "user-42")

        XCTAssertEqual(rec.sent.count, 1)
        let (path, body) = rec.sent[0]
        XCTAssertEqual(path, "/ingest/v1/sessions/start")
        XCTAssertEqual(body["sessionId"] as? String, session.id)
        XCTAssertFalse(session.id.isEmpty)
        XCTAssertEqual(body["release"] as? String, "1.2.3")
        XCTAssertEqual(body["environment"] as? String, "production")
        XCTAssertEqual(body["userId"] as? String, "user-42")
        XCTAssertEqual(body["sdkName"] as? String, "allstak-apple")
        XCTAssertEqual(body["sdkVersion"] as? String, "0.1.0")
        XCTAssertEqual(body["platform"] as? String, "cocoa")
    }

    func testStartWithoutUserOmitsUserId() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        let body = rec.sent[0].body
        // userId present-but-nil; the transport drops nils so the wire body omits it.
        XCTAssertNil(body["userId"] ?? nil)
    }

    func testStartIsIdempotent() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        let first = tracker.start()
        let second = tracker.start()
        XCTAssertEqual(first.id, second.id, "second start must reuse the same session")
        XCTAssertEqual(rec.sent.count, 1, "start must only POST once")
    }

    func testStartSkipsNetworkWhenTransportDisabled() {
        let rec = Recorder()
        let tracker = makeTracker(transportEnabled: false, recorder: rec)
        let session = tracker.start()
        XCTAssertTrue(rec.sent.isEmpty, "no key → no network call")
        // ...but the in-memory session still exists so status tracking works.
        XCTAssertEqual(tracker.currentSessionId, session.id)
    }

    // MARK: end payload shape + status transitions

    func testEndPostsOkWhenNoErrors() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.end()

        XCTAssertEqual(rec.sent.count, 2)
        let (path, body) = rec.sent[1]
        XCTAssertEqual(path, "/ingest/v1/sessions/end")
        XCTAssertEqual(body["status"] as? String, "ok")
        XCTAssertNotNil(body["sessionId"] as? String)
        XCTAssertNotNil(body["durationMs"] as? Int)
        XCTAssertGreaterThanOrEqual(body["durationMs"] as? Int ?? -1, 0)
    }

    func testHandledErrorTransitionsOkToErrored() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.recordError()
        tracker.end()
        XCTAssertEqual(rec.sent[1].body["status"] as? String, "errored")
    }

    func testCrashTransitionsToCrashedAndOverridesErrored() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.recordError()   // ok → errored
        tracker.recordCrash()   // errored → crashed (terminal)
        tracker.end()
        XCTAssertEqual(rec.sent[1].body["status"] as? String, "crashed")
    }

    func testCrashedNeverDowngradedByLaterError() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.recordCrash()   // ok → crashed
        tracker.recordError()   // must NOT downgrade to errored
        tracker.end()
        XCTAssertEqual(rec.sent[1].body["status"] as? String, "crashed")
    }

    func testExplicitFinalStatusWins() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.end(.abnormal)
        XCTAssertEqual(rec.sent[1].body["status"] as? String, "abnormal")
    }

    func testEndIsIdempotent() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        tracker.end()
        tracker.end()
        let endCount = rec.sent.filter { $0.path == "/ingest/v1/sessions/end" }.count
        XCTAssertEqual(endCount, 1, "end must only POST once")
    }

    func testCurrentSessionIdNilAfterEnd() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.start()
        XCTAssertNotNil(tracker.currentSessionId)
        tracker.end()
        XCTAssertNil(tracker.currentSessionId, "no session id once the session is closed")
    }

    func testEndWithoutStartIsNoOp() {
        let rec = Recorder()
        let tracker = makeTracker(recorder: rec)
        tracker.end()
        XCTAssertTrue(rec.sent.isEmpty)
    }

    // MARK: abnormal session recovery

    func testCleanShutdownDoesNotRecoverAbnormalOnNextStart() {
        let store = MemoryStore()
        let first = Recorder()
        let tracker = makeTracker(store: store, recorder: first)
        tracker.start()
        tracker.end()

        let second = Recorder()
        makeTracker(store: store, recorder: second).start()

        XCTAssertEqual(second.sent.filter { $0.path == "/ingest/v1/sessions/end" }.count, 0)
        XCTAssertEqual(second.sent.filter { $0.path == "/ingest/v1/sessions/start" }.count, 1)
    }

    func testOpenSessionIsRecoveredAsAbnormalOnNextStart() {
        let store = MemoryStore()
        let session = makeTracker(store: store, recorder: Recorder()).start()

        let second = Recorder()
        makeTracker(store: store, recorder: second).start()

        let recovered = second.sent.first { $0.path == "/ingest/v1/sessions/end" }?.body
        XCTAssertEqual(recovered?["sessionId"] as? String, session.id)
        XCTAssertEqual(recovered?["status"] as? String, "abnormal")
    }

    func testCrashedOpenSessionIsRecoveredAsCrashedOnNextStart() {
        let store = MemoryStore()
        let tracker = makeTracker(store: store, recorder: Recorder())
        let session = tracker.start()
        tracker.recordCrash()

        let second = Recorder()
        makeTracker(store: store, recorder: second).start()

        let recovered = second.sent.first { $0.path == "/ingest/v1/sessions/end" }?.body
        XCTAssertEqual(recovered?["sessionId"] as? String, session.id)
        XCTAssertEqual(recovered?["status"] as? String, "crashed")
    }

    func testCorruptSessionStateIsClearedSafely() {
        let store = MemoryStore(["version": 1, "bad": "shape"])
        let rec = Recorder()
        makeTracker(store: store, recorder: rec).start()
        XCTAssertEqual(rec.sent.filter { $0.path == "/ingest/v1/sessions/end" }.count, 0)
        XCTAssertEqual(rec.sent.filter { $0.path == "/ingest/v1/sessions/start" }.count, 1)
    }

    func testRecoveredAbnormalSessionIsNotReportedTwice() {
        let store = MemoryStore()
        makeTracker(store: store, recorder: Recorder()).start()

        let second = Recorder()
        let secondTracker = makeTracker(store: store, recorder: second)
        secondTracker.start()
        secondTracker.end()

        let third = Recorder()
        makeTracker(store: store, recorder: third).start()

        XCTAssertEqual(second.sent.filter {
            $0.path == "/ingest/v1/sessions/end" && $0.body["status"] as? String == "abnormal"
        }.count, 1)
        XCTAssertEqual(third.sent.filter {
            $0.path == "/ingest/v1/sessions/end" && $0.body["status"] as? String == "abnormal"
        }.count, 0)
    }

    // MARK: Session model unit semantics (mirrors the Java reference)

    func testSessionStatusEscalationModel() {
        let s = Session()
        XCTAssertEqual(s.status, .ok)
        s.recordError()
        XCTAssertEqual(s.status, .errored)
        XCTAssertEqual(s.errorCount, 1)
        s.recordCrash()
        XCTAssertEqual(s.status, .crashed)
        // crashed is terminal: another error must not downgrade it.
        s.recordError()
        XCTAssertEqual(s.status, .crashed)
        XCTAssertGreaterThanOrEqual(s.durationMs(), 0)
    }
}

import XCTest
@testable import AllStak

/// App-hang (ANR) detection: the pure `AppHangStateMachine` transition model and
/// the live `AppHangDetector` driven through its injectable clock / main-enqueue
/// seams (no real timer, no real hang), exactly like `SessionTracker` is tested
/// through its injected `sender`. Verifies hang begins exactly once at the
/// threshold, resolves on recovery, and never re-fires while still hung.
final class AppHangDetectorTests: XCTestCase {

    // MARK: AppHangStateMachine — pure transition model

    func testNoHangWhenPingsAreAnsweredPromptly() {
        let sm = AppHangStateMachine(threshold: 2.0)
        sm.recordPing(at: 0)
        sm.recordPong(at: 0.1) // answered well within threshold
        XCTAssertEqual(sm.evaluate(now: 0.2), .none)
        XCTAssertFalse(sm.isHung)
    }

    func testHangBeginsExactlyAtThreshold() {
        let sm = AppHangStateMachine(threshold: 2.0)
        sm.recordPing(at: 0) // never answered
        XCTAssertEqual(sm.evaluate(now: 1.9), .none, "below threshold → no hang")
        XCTAssertEqual(sm.evaluate(now: 2.0), .began(duration: 2.0), "at threshold → hang begins")
        XCTAssertTrue(sm.isHung)
    }

    func testHangDoesNotReFireWhileStillHung() {
        let sm = AppHangStateMachine(threshold: 2.0)
        sm.recordPing(at: 0)
        XCTAssertEqual(sm.evaluate(now: 2.0), .began(duration: 2.0))
        // Still no pong, deeper into the hang → must NOT emit a second `began`.
        XCTAssertEqual(sm.evaluate(now: 3.0), .none)
        XCTAssertEqual(sm.evaluate(now: 4.0), .none)
        XCTAssertTrue(sm.isHung)
    }

    func testHangResolvesWhenMainThreadRecovers() {
        let sm = AppHangStateMachine(threshold: 2.0)
        sm.recordPing(at: 0)
        XCTAssertEqual(sm.evaluate(now: 2.5), .began(duration: 2.5))
        // Main thread finally runs the probe.
        sm.recordPong(at: 2.6)
        XCTAssertEqual(sm.evaluate(now: 2.7), .resolved, "recovery emits resolved exactly once")
        XCTAssertFalse(sm.isHung)
        // ...and does not re-emit resolved.
        XCTAssertEqual(sm.evaluate(now: 2.8), .none)
    }

    func testResolvedEmittedOnceWhenFreshPingSupersedesStaleHang() {
        let sm = AppHangStateMachine(threshold: 2.0)
        sm.recordPing(at: 0)
        XCTAssertEqual(sm.evaluate(now: 2.5), .began(duration: 2.5))
        // A new probe round starts (fresh ping) while still flagged hung; the
        // fresh ping is within threshold → treated as recovered.
        sm.recordPing(at: 3.0)
        XCTAssertEqual(sm.evaluate(now: 3.1), .resolved)
        XCTAssertFalse(sm.isHung)
    }

    func testNonPositiveThresholdFallsBackToDefault() {
        // A misconfigured threshold must not make every tick a hang.
        let sm = AppHangStateMachine(threshold: 0)
        sm.recordPing(at: 0)
        XCTAssertEqual(sm.evaluate(now: 1.0), .none, "default 2.0s applies, below threshold")
        XCTAssertEqual(sm.evaluate(now: 2.0), .began(duration: 2.0))
    }

    // MARK: AppHangDetector — live wiring through injected seams

    /// A controllable clock + main-queue stub so the detector runs with zero real
    /// time and zero real hangs.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: TimeInterval = 0
        /// When `true`, the injected main-enqueue runs the probe synchronously
        /// (main thread responsive). When `false`, probes are dropped (hung).
        private var _responsive = true
        private(set) var hangs: [(duration: TimeInterval, stack: [String])] = []
        private(set) var resolves = 0

        var now: TimeInterval {
            lock.lock(); defer { lock.unlock() }; return _now
        }
        func advance(to t: TimeInterval) { lock.lock(); _now = t; lock.unlock() }
        func setResponsive(_ v: Bool) { lock.lock(); _responsive = v; lock.unlock() }
        var responsive: Bool { lock.lock(); defer { lock.unlock() }; return _responsive }

        func recordHang(_ d: TimeInterval, _ s: [String]) {
            lock.lock(); hangs.append((d, s)); lock.unlock()
        }
        func recordResolve() { lock.lock(); resolves += 1; lock.unlock() }
    }

    private func makeDetector(_ h: Harness, threshold: TimeInterval = 2.0) -> AppHangDetector {
        AppHangDetector(
            timeoutInterval: threshold,
            clock: { h.now },
            mainEnqueue: { probe in if h.responsive { probe() } },
            mainStackProvider: { ["frame0", "frame1"] },
            onHang: { d, s in h.recordHang(d, s) },
            onResolved: { h.recordResolve() })
    }

    func testDetectorReportsHangThroughInjectedSeams() {
        let h = Harness()
        let detector = makeDetector(h)

        // Each `tick()` evaluates the OUTSTANDING ping from the previous tick,
        // then enqueues a fresh one — a one-tick lag, exactly like the live timer.

        // Tick 1 at t=0: nothing outstanding yet → enqueues a ping which the
        // responsive stub answers synchronously (pong recorded).
        detector.tick()
        XCTAssertTrue(h.hangs.isEmpty)

        // Main thread goes unresponsive: the next enqueued probe is dropped.
        h.setResponsive(false)
        // Tick 2 at t=0.1: the t=0 ping was already answered → no hang; enqueues a
        // fresh ping at t=0.1 that is now dropped (unresponsive).
        h.advance(to: 0.1)
        detector.tick()
        XCTAssertTrue(h.hangs.isEmpty)

        // Tick 3 at t=3.0: the t=0.1 ping is still unanswered and now past the
        // 2.0s threshold → hang begins exactly once.
        h.advance(to: 3.0)
        detector.tick()
        XCTAssertEqual(h.hangs.count, 1, "exactly one hang reported")
        XCTAssertGreaterThanOrEqual(h.hangs[0].duration, 2.0)
        XCTAssertEqual(h.hangs[0].stack, ["frame0", "frame1"])

        // Still hung → no duplicate hang.
        h.advance(to: 5.0)
        detector.tick()
        XCTAssertEqual(h.hangs.count, 1, "no duplicate hang while still hung")
    }

    func testDetectorReportsResolveWhenMainThreadRecovers() {
        let h = Harness()
        let detector = makeDetector(h)
        detector.tick()                                  // t=0 responsive
        h.setResponsive(false)
        h.advance(to: 0.1); detector.tick()              // enqueue ping that hangs
        h.advance(to: 3.0); detector.tick()              // hang begins
        XCTAssertEqual(h.hangs.count, 1)

        // Main thread recovers: probes run again.
        h.setResponsive(true)
        h.advance(to: 4.0); detector.tick()              // fresh ping answered; recovery observed
        h.advance(to: 4.1); detector.tick()
        XCTAssertGreaterThanOrEqual(h.resolves, 1, "recovery reported")
    }

    func testDetectorStartStopIdempotentDoesNotCrash() {
        let h = Harness()
        let detector = makeDetector(h)
        detector.start()
        detector.start() // idempotent
        detector.stop()
        detector.stop()  // idempotent
    }
}

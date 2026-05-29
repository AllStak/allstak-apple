import XCTest
@testable import AllStak

/// Watchdog / OOM termination inference. Exhaustively exercises the pure
/// `WatchdogTerminationLogic.shouldReport` decision table (marker present/absent ×
/// crash recorded × foreground × debugger × app/OS update) and the
/// `WatchdogTerminationTracker` marker lifecycle on a temp `CrashStore`.
final class WatchdogTerminationTests: XCTestCase {

    private func tempStore() -> CrashStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("allstak-watchdog-tests-" + UUID().uuidString)
        return CrashStore(directory: dir)
    }

    /// A foreground, non-debugged, same-release/OS prior marker — the ONLY shape
    /// that should be reported as a watchdog termination.
    private func foregroundMarker(release: String? = "1.0.0",
                                  os: String? = "17.0.0",
                                  debugging: Bool = false) -> AppRunStateMarker {
        AppRunStateMarker(release: release, osVersion: os, isForeground: true,
                          isDebugging: debugging, startedAt: 1000)
    }

    private func inputs(marker: AppRunStateMarker?,
                        crashRecorded: Bool = false,
                        isDebuggingNow: Bool = false,
                        currentRelease: String? = "1.0.0",
                        currentOS: String? = "17.0.0") -> WatchdogTerminationInputs {
        WatchdogTerminationInputs(
            priorMarker: marker,
            crashRecorded: crashRecorded,
            isDebuggingNow: isDebuggingNow,
            currentRelease: currentRelease,
            currentOSVersion: currentOS,
            isUnderTests: false) // exercise the real decision, not the test guard
    }

    // MARK: decision table

    func testReportsWhenMarkerForegroundNoCrashNoUpdate() {
        XCTAssertTrue(WatchdogTerminationLogic.shouldReport(inputs(marker: foregroundMarker())))
    }

    func testDoesNotReportWhenNoMarker() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(inputs(marker: nil)))
    }

    func testDoesNotReportWhenCrashRecorded() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(), crashRecorded: true)))
    }

    func testDoesNotReportWhenPriorRunWasBackground() {
        let bg = AppRunStateMarker(release: "1.0.0", osVersion: "17.0.0",
                                   isForeground: false, isDebugging: false, startedAt: 1000)
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(inputs(marker: bg)))
    }

    func testDoesNotReportWhenDebuggerWasAttachedOnPriorRun() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(debugging: true))))
    }

    func testDoesNotReportWhenDebuggerAttachedNow() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(), isDebuggingNow: true)))
    }

    func testDoesNotReportAcrossAppUpdate() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(release: "1.0.0"), currentRelease: "1.1.0")))
    }

    func testDoesNotReportAcrossOSUpdate() {
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(os: "16.0.0"), currentOS: "17.0.0")))
    }

    func testReportsWhenReleaseUnknownEitherSide() {
        // A nil release on either side cannot prove an update → still report
        // (the foreground/no-crash/no-debugger guards already passed).
        XCTAssertTrue(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(release: nil), currentRelease: "1.0.0")))
        XCTAssertTrue(WatchdogTerminationLogic.shouldReport(
            inputs(marker: foregroundMarker(release: "1.0.0"), currentRelease: nil)))
    }

    func testNeverReportsUnderTestHarness() {
        let underTest = WatchdogTerminationInputs(
            priorMarker: foregroundMarker(), crashRecorded: false, isDebuggingNow: false,
            currentRelease: "1.0.0", currentOSVersion: "17.0.0", isUnderTests: true)
        XCTAssertFalse(WatchdogTerminationLogic.shouldReport(underTest))
    }

    // MARK: marker lifecycle on CrashStore

    func testWriteReadClearRunStateMarker() {
        let store = tempStore()
        XCTAssertNil(store.runState(), "no marker initially")
        let marker = foregroundMarker()
        store.writeRunState(marker)
        XCTAssertEqual(store.runState(), marker)
        store.clearRunState()
        XCTAssertNil(store.runState(), "cleared")
    }

    /// Thread-safe sink so the fire-and-forget reporter seam can be asserted
    /// without a Swift 6 Sendable capture warning.
    private final class ReportSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _markers: [AppRunStateMarker] = []
        func record(_ m: AppRunStateMarker) { lock.lock(); _markers.append(m); lock.unlock() }
        var markers: [AppRunStateMarker] { lock.lock(); defer { lock.unlock() }; return _markers }
    }

    func testTrackerArmsMarkerAndReportsNothingUnderTests() {
        let store = tempStore()
        let sink = ReportSink()
        let tracker = WatchdogTerminationTracker(
            store: store, release: "1.0.0", osVersion: "17.0.0",
            reporter: { sink.record($0) })

        // A surviving foreground marker exists; reconciliation under the test
        // harness must NOT report (isRunningUnderTests guard) but MUST still arm a
        // fresh marker for this launch.
        store.writeRunState(foregroundMarker())
        let didReport = tracker.reconcileAndArm(crashRecorded: false,
                                                isForeground: true, isDebugging: false)
        XCTAssertFalse(didReport, "no report under the test harness")
        XCTAssertTrue(sink.markers.isEmpty)
        XCTAssertNotNil(store.runState(), "this launch's marker is armed")
    }

    func testBackgroundTransitionClearsMarker() {
        let store = tempStore()
        let tracker = WatchdogTerminationTracker(
            store: store, release: "1.0.0", osVersion: "17.0.0", reporter: { _ in })
        store.writeRunState(foregroundMarker())
        tracker.updateForeground(false, isDebugging: false)
        XCTAssertNil(store.runState(), "backgrounding clears the marker (explained exit)")
    }

    func testForegroundTransitionRewritesForegroundMarker() {
        let store = tempStore()
        let tracker = WatchdogTerminationTracker(
            store: store, release: "1.0.0", osVersion: "17.0.0", reporter: { _ in })
        tracker.updateForeground(true, isDebugging: false)
        let m = store.runState()
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.isForeground, true)
        XCTAssertEqual(m?.release, "1.0.0")
    }

    func testClearRemovesMarker() {
        let store = tempStore()
        let tracker = WatchdogTerminationTracker(
            store: store, release: "1.0.0", osVersion: "17.0.0", reporter: { _ in })
        store.writeRunState(foregroundMarker())
        tracker.clear()
        XCTAssertNil(store.runState())
    }
}

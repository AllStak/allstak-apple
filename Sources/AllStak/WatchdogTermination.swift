import Foundation

// MARK: - Watchdog / OOM termination tracking
//
// Some app deaths give our handlers NO chance to run: the OS watchdog kills an
// unresponsive app, or the kernel reclaims a memory-hungry app (OOM). These leave
// no NSException and no POSIX signal — the process just vanishes. We infer them
// the way sentry-cocoa does (`SentryWatchdogTerminationLogic`):
//
//   On launch we persist a run-state marker. We clear it on every *explained*
//   exit: a clean termination, entering background, or a recorded crash. On the
//   NEXT launch, if the marker is STILL present, the prior process died without
//   any explanation we recognise. If, in addition, the prior run was in the
//   FOREGROUND, no crash was recorded, no debugger was attached, and neither the
//   app nor the OS was updated between runs, we attribute the death to a watchdog
//   / OOM termination and report it with the distinct `"watchdog_termination"`
//   mechanism.
//
// The decision is a PURE function (`WatchdogTerminationLogic.shouldReport`) over
// an explicit input struct, so the full decision table (marker present/absent ×
// crash recorded × foreground × debugger × update) is exhaustively unit-testable
// without any disk or process state.

/// The inputs to the watchdog-termination inference, captured on the current
/// launch about the PREVIOUS launch.
struct WatchdogTerminationInputs: Equatable {
    /// The prior launch's run-state marker, if it survived (i.e. the prior exit
    /// was not explained). `nil` means a clean / explained prior exit.
    let priorMarker: AppRunStateMarker?
    /// `true` when a crash report (NSException or signal) from the prior launch
    /// was found — that crash, not a watchdog kill, is the real cause.
    let crashRecorded: Bool
    /// `true` when a debugger is attached to THIS process. A paused debugger on
    /// the prior run can masquerade as a termination, so we never report while
    /// debugging.
    let isDebuggingNow: Bool
    /// This launch's resolved release, to detect an app update between runs.
    let currentRelease: String?
    /// This launch's OS version, to detect an OS update between runs.
    let currentOSVersion: String?
    /// `true` when this launch is running under the unit-test harness (suppresses
    /// reporting, mirroring the rest of the SDK).
    let isUnderTests: Bool
}

/// Pure decision core for watchdog / OOM termination inference. No I/O.
enum WatchdogTerminationLogic {

    /// Decide whether the previous launch should be reported as a watchdog / OOM
    /// termination. Returns `true` only when ALL false-positive guards pass.
    static func shouldReport(_ input: WatchdogTerminationInputs) -> Bool {
        // Never under the test harness.
        if input.isUnderTests { return false }
        // No surviving marker → the prior exit was explained (clean exit, entered
        // background, or a crash that cleared the marker). Not a watchdog kill.
        guard let marker = input.priorMarker else { return false }
        // A recorded crash is the real cause; do not double-report.
        if input.crashRecorded { return false }
        // The prior run must have been in the foreground. Background terminations
        // are normal OS reclaim behaviour, not watchdog kills.
        guard marker.isForeground else { return false }
        // A debugger (prior or current) makes pause/stop look like a termination.
        if marker.isDebugging || input.isDebuggingNow { return false }
        // An app update between runs explains the prior process going away.
        if let prior = marker.release, let current = input.currentRelease,
           prior != current {
            return false
        }
        // An OS update between runs likewise explains it.
        if let priorOS = marker.osVersion, let currentOS = input.currentOSVersion,
           priorOS != currentOS {
            return false
        }
        return true
    }
}

/// Live watchdog-termination tracker. Owns the run-state marker lifecycle on top
/// of `CrashStore`, performs the next-launch inference, and reports a detected
/// termination through an injected, fire-and-forget reporter seam (mirroring the
/// `SessionTracker` sender seam so the wiring stays out of unit tests).
final class WatchdogTerminationTracker: @unchecked Sendable {

    /// Distinct mechanism stamped on reported events.
    static let mechanism = "watchdog_termination"

    /// Fire-and-forget reporter seam. `(timestamp, mainThreadGoneRelease)`. Must
    /// not throw. Production wires this to the capture/transport path.
    typealias Reporter = @Sendable (_ marker: AppRunStateMarker) -> Void

    private let store: CrashStore
    private let release: String?
    private let osVersion: String?
    private let reporter: Reporter

    init(store: CrashStore, release: String?, osVersion: String?, reporter: @escaping Reporter) {
        self.store = store
        self.release = release
        self.osVersion = osVersion
        self.reporter = reporter
    }

    /// Run the next-launch inference using the prior marker, then write a fresh
    /// marker for THIS launch. `crashRecorded` and `isDebugging`/`isForeground`
    /// are supplied by the caller (it knows whether a crash flush found anything,
    /// and the current UIKit foreground state).
    ///
    /// Returns `true` if a watchdog termination was reported (visible for testing
    /// — production ignores the result).
    @discardableResult
    func reconcileAndArm(crashRecorded: Bool,
                         isForeground: Bool,
                         isDebugging: Bool) -> Bool {
        let prior = store.runState()
        let inputs = WatchdogTerminationInputs(
            priorMarker: prior,
            crashRecorded: crashRecorded,
            isDebuggingNow: isDebugging,
            currentRelease: release,
            currentOSVersion: osVersion,
            isUnderTests: AllStakClient.isRunningUnderTests)
        var reported = false
        if WatchdogTerminationLogic.shouldReport(inputs), let prior {
            reporter(prior)
            reported = true
        }
        // Arm this launch's marker. Foreground/debugger captured now; updated by
        // lifecycle transitions.
        store.writeRunState(AppRunStateMarker(
            release: release,
            osVersion: osVersion,
            isForeground: isForeground,
            isDebugging: isDebugging,
            startedAt: Date().timeIntervalSince1970))
        return reported
    }

    /// Update the persisted foreground flag (on foreground/background lifecycle
    /// transitions). When backgrounding we additionally clear the marker — a
    /// background termination is normal and must not be reported next launch.
    func updateForeground(_ isForeground: Bool, isDebugging: Bool) {
        if isForeground {
            store.writeRunState(AppRunStateMarker(
                release: release,
                osVersion: osVersion,
                isForeground: true,
                isDebugging: isDebugging,
                startedAt: Date().timeIntervalSince1970))
        } else {
            // Entered background → explained exit path; clear the marker.
            store.clearRunState()
        }
    }

    /// Clear the marker on a clean termination / when a crash is recorded, so the
    /// next launch does not infer a phantom watchdog termination.
    func clear() {
        store.clearRunState()
    }
}

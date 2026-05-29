import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Small, fail-open platform probes used by watchdog-termination inference and
/// app-hang reporting. Each probe degrades gracefully (returns a safe default)
/// on headless / non-UIKit platforms so the SDK never freezes or crashes.
enum Platform {

    /// The OS version string (e.g. "17.4.1"). Used to detect an OS update between
    /// runs, which must NOT be reported as a watchdog termination.
    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// `true` when a debugger is attached to this process. A paused/stopped
    /// debugger looks like a hang/termination, so the SDK never reports watchdog
    /// terminations while debugging. Uses the standard `sysctl(KERN_PROC)` +
    /// `P_TRACED` check; fail-open to `false` if it cannot be determined.
    static func isDebuggerAttached() -> Bool {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(ptr.baseAddress, u_int(ptr.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #else
        return false
        #endif
    }

    /// `true` when the app is in the foreground (UIKit). On non-UIKit / headless
    /// platforms there is no foreground concept, so we report `true` — a process
    /// that vanishes without explanation on such platforms is still abnormal and
    /// the rest of the watchdog guards (crash recorded / update / debugger) still
    /// apply. Must be read on the main thread; safe fallback otherwise.
    static func isForeground() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        if Thread.isMainThread {
            return UIApplication.shared.applicationState != .background
        }
        // Off the main thread we cannot safely touch UIApplication; assume
        // foreground (conservative — the marker is corrected on the next
        // lifecycle transition, which runs on the main thread).
        return true
        #else
        return true
        #endif
    }
}

import Foundation

// Global state — uncaught-exception handlers are C function pointers and cannot
// capture context, so they reach the store + the previous handler via globals.
nonisolated(unsafe) private var g_crashStore: CrashStore?
nonisolated(unsafe) private var g_previousExceptionHandler: (@convention(c) (NSException) -> Void)?

private func allstakHandleException(_ exception: NSException) {
    if let store = g_crashStore {
        let report = CrashReport(
            kind: "nsexception",
            name: exception.name.rawValue,
            message: exception.reason ?? "",
            addresses: exception.callStackReturnAddresses.map { $0.uintValue },
            timestamp: Date().timeIntervalSince1970)
        try? store.write(report)
        // Stamp the open release-health session as crashed so the next launch
        // ends it with the right terminal status. Best-effort; never throws.
        store.markOpenSession(status: "crashed")
    }
    // Chain any previously-installed handler so we don't swallow other reporters.
    g_previousExceptionHandler?(exception)
}

/// Installs crash capture and flushes crashes from previous launches.
///
/// Covers both crash channels on Apple platforms:
///   * uncaught `NSException`s (Obj-C exceptions) via `NSSetUncaughtExceptionHandler`;
///   * native POSIX signal crashes (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP —
///     force-unwrap traps, out-of-bounds, bad pointer access, etc.) via
///     async-signal-safe `sigaction` handlers (see SignalCrashHandler).
///
/// Signal capture is the dominant path for real Swift crashes; it is implemented
/// here but the live in-process handler can only be fully validated on-device
/// (you cannot safely trigger a real SIGSEGV in unit tests). The record writer
/// and the next-launch reader/parser ARE unit-tested.
public enum CrashReporter {

    /// Send crashes recorded in previous launches, then arm capture for this one.
    /// Order matters: pending reports use the PREVIOUS launch's image layout, so
    /// they're sent before this launch overwrites it.
    public static func install(store: CrashStore, client: AllStakClient) {
        sendPending(store: store, client: client)
        store.saveSessionImages(BinaryImageProvider.current())

        g_crashStore = store
        g_previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(allstakHandleException)

        // Arm async-signal-safe handlers. This pre-allocates the alt-stack, record
        // buffer, and frame buffer, and pre-opens the crash fd — all done here in
        // normal context, never inside the handler.
        SignalCrashHandler.install(crashFileURL: store.signalCrashFileURL())
    }

    static func sendPending(store: CrashStore, client: AllStakClient) {
        var reports = store.pendingReports()
        // A signal crash from the previous launch is persisted as a raw binary
        // record by the handler; parse it (normal context) and treat it like any
        // other pending report.
        if let signalReport = store.pendingSignalReport() {
            reports.append(signalReport)
        }
        guard !reports.isEmpty else { return }
        let images = store.sessionImages()
        for report in reports {
            client.sendCrash(report, images: images)
        }
        store.clearReports()
    }
}

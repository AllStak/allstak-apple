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
    }
    // Chain any previously-installed handler so we don't swallow other reporters.
    g_previousExceptionHandler?(exception)
}

/// Installs crash capture and flushes crashes from previous launches.
///
/// Slice 1 covers uncaught `NSException`s (Objective-C exceptions, `try!`/
/// force-unwrap traps that route through NSException). Async-signal-safe `signal`
/// handlers — which catch the remaining native Swift crashes (SIGSEGV/SIGABRT/…)
/// — are the next slice; they require on-device verification.
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
    }

    static func sendPending(store: CrashStore, client: AllStakClient) {
        let reports = store.pendingReports()
        guard !reports.isEmpty else { return }
        let images = store.sessionImages()
        for report in reports {
            client.sendCrash(report, images: images)
        }
        store.clearReports()
    }
}

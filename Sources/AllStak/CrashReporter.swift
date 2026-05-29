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

    /// Send crashes recorded in previous launches through the reliable transport,
    /// removing each on-disk record ONLY after the transport acknowledges it
    /// (2xx / permanent 4xx / 401 / handed to the persistent spool). Previously
    /// every record was cleared after a single fire-and-forget POST regardless of
    /// HTTP success — a failed/offline flush silently lost the crash. Now a record
    /// that could not be delivered AND could not be spooled is KEPT for the next
    /// launch. Each flush is async/detached and fail-open; never blocks launch.
    static func sendPending(store: CrashStore, client: AllStakClient) {
        let images = store.sessionImages()

        // NSException records: one file each, removed only after ack.
        for (url, report) in store.pendingReportsWithURLs() {
            client.flushCrash(report, images: images) { resolution in
                if resolution == .settled { store.removeReport(at: url) }
            }
        }

        // Signal crash: a single fixed-location binary record. Parsed NON-
        // destructively (peek) so it's removed only after the transport acks it.
        if let signalReport = store.peekSignalReport() {
            client.flushCrash(signalReport, images: images) { resolution in
                if resolution == .settled { store.removeSignalReport() }
            }
        }
    }
}

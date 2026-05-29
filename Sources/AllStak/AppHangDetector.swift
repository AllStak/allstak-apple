import Foundation

// MARK: - App-hang (ANR) detection
//
// A background watchdog periodically posts a no-op block to the main queue and
// records the time. The main thread, when it gets around to running the block,
// stamps "I responded at T". If the watchdog observes that the most-recent ping
// it sent has gone unanswered for longer than the configured threshold (default
// 2.0s, Sentry-cocoa parity), the main thread is hung and an app-hang event is
// recorded; when the main thread finally runs the outstanding block, the hang is
// resolved/cleared.
//
// The timing + detection logic is split into a PURE state machine
// (`AppHangStateMachine`) that knows nothing about threads, queues, or wall-clock
// time — it is driven entirely by injected "now" values and ping/pong events — so
// the hang-detection behaviour is unit-testable without ever producing a real
// hang. The live `AppHangDetector` is a thin wrapper that wires a real timer +
// `DispatchQueue.main` to that state machine, exactly like `SessionTracker`'s
// injected `sender` seam keeps its network I/O out of the unit tests.

// MARK: State machine (pure, fully unit-testable)

/// The pure decision core of app-hang detection. Holds no timers and does no
/// I/O. The owner feeds it monotonic timestamps and main-thread responses; it
/// answers "is the main thread currently hung, and did that state just change?".
///
/// Model:
///   * `recordPing(at:)` — the watchdog just enqueued a probe onto the main queue
///     at time `t`. Only the most-recent unanswered ping matters.
///   * `recordPong(at:)` — the main thread ran the probe at time `t`; it is
///     responsive again.
///   * `evaluate(now:)` — called on each watchdog tick; returns a transition when
///     the hung/responsive state flips (so the owner emits exactly one event per
///     hang and exactly one resolve).
final class AppHangStateMachine: @unchecked Sendable {

    /// Result of an `evaluate` tick — the edge, if any, that just occurred.
    enum Transition: Equatable {
        /// The main thread has just been observed unresponsive for >= the
        /// threshold. `duration` is how long the outstanding ping has been
        /// pending. Emitted exactly once per hang.
        case began(duration: TimeInterval)
        /// The previously-hung main thread has recovered. Emitted exactly once.
        case resolved
        /// No state change this tick.
        case none
    }

    private let threshold: TimeInterval
    private let lock = NSLock()

    /// Time of the most-recent ping the watchdog enqueued and that has not yet
    /// been answered by a pong. `nil` when there is no outstanding ping.
    private var outstandingPingAt: TimeInterval?
    /// Whether we are currently reporting the main thread as hung.
    private var hung = false

    init(threshold: TimeInterval) {
        // Defend against a non-positive / NaN threshold so a misconfiguration can
        // never make every tick look like a hang. Falls back to the 2.0s default.
        self.threshold = (threshold.isFinite && threshold > 0) ? threshold : 2.0
    }

    /// The watchdog enqueued a probe at `t`. Supersedes any earlier unanswered
    /// ping (we only ever track the latest outstanding one).
    func recordPing(at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        outstandingPingAt = t
    }

    /// The main thread ran the probe at `t`. Clears the outstanding ping. The
    /// hung→responsive transition is emitted by the next `evaluate`, so callers
    /// get a single resolve edge regardless of how recovery is observed.
    func recordPong(at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        // Only clear if this pong answers the outstanding ping (or a later one).
        if let p = outstandingPingAt, t >= p {
            outstandingPingAt = nil
        }
    }

    /// Evaluate the current state at monotonic time `now`. Returns the edge that
    /// just occurred (at most one began/resolved per call).
    func evaluate(now: TimeInterval) -> Transition {
        lock.lock(); defer { lock.unlock() }
        if let pending = outstandingPingAt {
            let waited = now - pending
            if waited >= threshold {
                if !hung {
                    hung = true
                    return .began(duration: waited)
                }
                return .none // already reported this hang; do not re-emit.
            }
            // Outstanding ping but still within threshold.
            if hung {
                // It was hung, the ping is fresh again (a new ping superseded the
                // old one while still hung) → treat as recovered.
                hung = false
                return .resolved
            }
            return .none
        }
        // No outstanding ping → main thread is responsive.
        if hung {
            hung = false
            return .resolved
        }
        return .none
    }

    /// Whether the state machine currently considers the main thread hung.
    var isHung: Bool {
        lock.lock(); defer { lock.unlock() }
        return hung
    }
}

// MARK: Live detector (thin wiring over the state machine)

/// Live app-hang watchdog. Owns a background timer that, on each tick, asks the
/// `AppHangStateMachine` whether the main thread is hung and reports the edges
/// via two injected, fire-and-forget callbacks (`onHang` / `onResolved`) — the
/// same seam shape `SessionTracker` uses for its network sender, so the wiring is
/// inert in unit tests.
///
/// All work is off the main thread except the tiny ping block; the detector
/// never blocks or freezes the host. Fully fail-open: if anything goes wrong the
/// watchdog simply stops.
final class AppHangDetector: @unchecked Sendable {

    /// Injected seam: a monotonic clock. Defaults to `Date.timeIntervalSince...`
    /// via `ProcessInfo.systemUptime`, which is immune to wall-clock changes.
    typealias Clock = @Sendable () -> TimeInterval
    /// Injected seam: enqueue `probe` onto the main run loop / main queue.
    /// Defaults to `DispatchQueue.main.async`. Tests pass a synchronous stub.
    typealias MainEnqueue = @Sendable (_ probe: @escaping @Sendable () -> Void) -> Void

    /// Reported when a hang begins. `(duration, mainThreadStack)`. The stack is
    /// the best-effort main-thread call stack symbols if obtainable; empty when
    /// not. Fire-and-forget; must not throw.
    typealias HangHandler = @Sendable (_ duration: TimeInterval, _ stack: [String]) -> Void
    /// Reported when a hang resolves. Fire-and-forget; must not throw.
    typealias ResolveHandler = @Sendable () -> Void

    private let machine: AppHangStateMachine
    private let pollInterval: TimeInterval
    private let clock: Clock
    private let mainEnqueue: MainEnqueue
    private let mainStackProvider: @Sendable () -> [String]
    private let onHang: HangHandler
    private let onResolved: ResolveHandler

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var running = false
    private let queue = DispatchQueue(label: "com.allstak.apphang", qos: .utility)

    /// - Parameters:
    ///   - timeoutInterval: hang threshold (seconds). The poll interval is derived
    ///     as a fraction of it so a hang is detected within ~1 poll of the
    ///     threshold.
    ///   - clock / mainEnqueue / mainStackProvider: injectable seams. Production
    ///     callers omit them; tests inject deterministic stubs.
    init(timeoutInterval: TimeInterval,
         clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
         mainEnqueue: MainEnqueue? = nil,
         mainStackProvider: @escaping @Sendable () -> [String] = { AppHangDetector.mainThreadStack() },
         onHang: @escaping HangHandler,
         onResolved: @escaping ResolveHandler) {
        let timeout = (timeoutInterval.isFinite && timeoutInterval > 0) ? timeoutInterval : 2.0
        self.machine = AppHangStateMachine(threshold: timeout)
        // Poll at a fraction of the threshold (>= 100ms) so detection latency is
        // bounded by ~one poll, without busy-spinning.
        self.pollInterval = max(0.1, timeout / 5.0)
        self.clock = clock
        self.mainEnqueue = mainEnqueue ?? { probe in DispatchQueue.main.async(execute: probe) }
        self.mainStackProvider = mainStackProvider
        self.onHang = onHang
        self.onResolved = onResolved
    }

    /// Begin watching. Idempotent. Off-main; never blocks the caller.
    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        lock.unlock()
        timer.resume()
        // Prime the first ping immediately so a hang at launch is caught.
        enqueuePing()
    }

    /// Stop watching. Idempotent.
    func stop() {
        lock.lock()
        running = false
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    /// One watchdog tick: send a fresh probe and evaluate the outstanding state.
    /// Visible for testing so the deterministic seam can drive it without a real
    /// timer.
    func tick() {
        let transition = machine.evaluate(now: clock())
        switch transition {
        case .began(let duration):
            // Capture the (likely still-hung) main-thread stack best-effort.
            let stack = mainStackProvider()
            onHang(duration, stack)
        case .resolved:
            onResolved()
        case .none:
            break
        }
        enqueuePing()
    }

    /// Enqueue a fresh probe onto the main queue and record the ping time. When
    /// the main thread runs the probe it records the pong, clearing the
    /// outstanding ping for the next tick.
    private func enqueuePing() {
        let now = clock()
        machine.recordPing(at: now)
        let machine = self.machine
        let clock = self.clock
        mainEnqueue { machine.recordPong(at: clock()) }
    }

    /// Best-effort symbolic main-thread stack. On Apple platforms the live
    /// main-thread frames cannot be safely walked from another thread without
    /// platform crash-reporter machinery, so we fall back to the current call
    /// stack symbols. The backend symbolicates addresses from the dSYM regardless.
    static func mainThreadStack() -> [String] {
        Thread.callStackSymbols
    }
}

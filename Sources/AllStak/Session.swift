import Foundation

/// Lifecycle status of a release-health session.
///
/// Vocabulary matches the AllStak backend's `/ingest/v1/sessions/end` contract
/// and standard release-health conventions (mirrors the Java SDK
/// `dev.allstak.session.SessionStatus`):
///
/// - ``ok`` — session ended normally with at most non-fatal logs.
/// - ``errored`` — at least one *handled* error-level (or higher) event landed
///   during the session, but the process kept running.
/// - ``crashed`` — an *unhandled* / fatal crash ended the process. The SDK only
///   reports this when it observes the crash itself (signal / NSException), or
///   on the next launch if a prior session was left open by a crash.
/// - ``abnormal`` — process ended without a normal flush. Reserved.
enum SessionStatus: String, Codable, Sendable {
    case ok
    case errored
    case crashed
    case abnormal

    /// Backend wire value — lower-case string the `/sessions/end` DTO expects.
    var wireValue: String { rawValue }
}

protocol SessionStateStore: AnyObject {
    func read() -> [String: Any]?
    func write(_ state: [String: Any])
    func clear()
}

final class UserDefaultsSessionStateStore: SessionStateStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func read() -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    func write(_ state: [String: Any]) {
        defaults.set(state, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// A single release-health session. One-per-process / app-launch.
///
/// Mirrors the Java SDK `dev.allstak.session.Session`: status escalates
/// `ok → errored → crashed` and never downgrades. Mutation is guarded by a lock
/// so a crash handler / error capture on another thread can mark the session
/// without data races.
final class Session: @unchecked Sendable {

    let id: String
    let startedAt: Date

    private let lock = NSLock()
    private var _status: SessionStatus = .ok
    private var _errorCount: Int = 0

    /// Fresh session with a generated id and `startedAt = now`.
    convenience init() {
        self.init(id: UUID().uuidString, startedAt: Date())
    }

    init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    var status: SessionStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var errorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _errorCount
    }

    /// Increment the error counter and bump status to ``SessionStatus/errored``
    /// unless the session has already escalated to a terminal status.
    func recordError() {
        lock.lock(); defer { lock.unlock() }
        _errorCount += 1
        if _status == .ok { _status = .errored }
    }

    /// Mark a terminal crashed status (overrides errored). Used by crash handlers.
    func recordCrash() {
        lock.lock(); defer { lock.unlock() }
        _status = .crashed
        _errorCount += 1
    }

    /// Duration from start to now in milliseconds, floored at 0.
    func durationMs() -> Int {
        let ms = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        return max(0, ms)
    }
}

/// Single-session release-health tracker for one ``AllStakClient``.
///
/// On ``start(userId:)`` it POSTs a `/ingest/v1/sessions/start` envelope with the
/// session id, the resolved release (falling back to the SDK version), and the
/// SDK identity. On ``end(_:)`` it POSTs `/ingest/v1/sessions/end` with the final
/// status + total duration. Errored / crashed transitions are recorded in-memory
/// only; just the terminal call performs network I/O, so per-error latency is
/// unaffected.
///
/// Re-entrancy safe: a second ``start(userId:)`` is a no-op, and once ended the
/// tracker does not re-arm. All network I/O is best-effort and fail-open — the
/// injected `sender` is fire-and-forget and never throws into the caller.
///
/// Release-health sessions are **never sampled**: the start POST is always
/// attempted (subject only to a non-empty API key, signalled by `transportEnabled`).
final class SessionTracker: @unchecked Sendable {

    static let pathStart = "/ingest/v1/sessions/start"
    static let pathEnd = "/ingest/v1/sessions/end"

    /// Seam for network I/O. `(path, jsonBody)`. Fire-and-forget; must not throw.
    typealias Sender = (_ path: String, _ body: [String: Any?]) -> Void

    private let release: String
    private let environment: String?
    private let sdkName: String
    private let sdkVersion: String
    private let platform: String
    private let transportEnabled: Bool
    private let sender: Sender
    private let stateStore: SessionStateStore?

    private let lock = NSLock()
    private var active: Session?
    private var ended = false

    private static let stateVersion = 1
    private static let stateMaxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let recoveryLockSeconds: TimeInterval = 30
    private static let recoveryMaxAttempts = 3

    init(release: String,
         environment: String?,
         sdkName: String,
         sdkVersion: String,
         platform: String,
         transportEnabled: Bool,
         stateStore: SessionStateStore? = nil,
         sender: @escaping Sender) {
        self.release = release
        self.environment = environment
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.platform = platform
        self.transportEnabled = transportEnabled
        self.stateStore = stateStore
        self.sender = sender
    }

    /// Idempotent. Starts (or reuses) the active session and fires the
    /// `/sessions/start` POST. `userId` is attached when a user is set at init.
    /// Returns the session that is now active.
    @discardableResult
    func start(userId: String? = nil) -> Session {
        lock.lock()
        if let existing = active {
            lock.unlock()
            return existing
        }
        let session = Session()
        active = session
        let enabled = transportEnabled
        lock.unlock()
        recoverPreviousSession()
        writeOpenState(session, userId: userId)

        // Transport disabled (missing/blank key): keep the in-memory tracker so
        // errored/crashed transitions still set a sensible final status, but skip
        // the network call — exactly like the Java reference.
        guard enabled else { return session }

        let body: [String: Any?] = [
            "sessionId": session.id,
            "release": release,
            "environment": environment,
            "userId": userId,
            "sdkName": sdkName,
            "sdkVersion": sdkVersion,
            "platform": platform,
        ]
        sender(Self.pathStart, body)
        return session
    }

    /// The id of the active session, or `nil` when no session is open. Attached
    /// to every captured error/event so the backend can mark the session
    /// errored/crashed server-side.
    var currentSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return ended ? nil : active?.id
    }

    /// Record a handled error against the active session. No I/O.
    func recordError() {
        lock.lock(); let s = ended ? nil : active; lock.unlock()
        s?.recordError()
        if let s { writeOpenState(s, userId: nil) }
    }

    /// Record an unhandled crash against the active session. No I/O — the
    /// end-of-session POST carries the `crashed` status.
    func recordCrash() {
        lock.lock(); let s = ended ? nil : active; lock.unlock()
        s?.recordCrash()
        if let s { writeOpenState(s, userId: nil) }
    }

    /// Terminate the session and POST `/sessions/end`. Idempotent. When
    /// `finalStatus` is `nil` the session's own accumulated status is used.
    func end(_ finalStatus: SessionStatus? = nil) {
        lock.lock()
        if ended { lock.unlock(); return }
        guard let session = active else { lock.unlock(); return }
        ended = true
        active = nil
        let enabled = transportEnabled
        lock.unlock()

        let status = finalStatus ?? session.status
        writeClosedState(session, status: status)
        guard enabled else { return }

        let body: [String: Any?] = [
            "sessionId": session.id,
            "durationMs": session.durationMs(),
            "status": status.wireValue,
        ]
        sender(Self.pathEnd, body)
    }

    private func recoverPreviousSession() {
        guard let store = stateStore, var state = store.read() else { return }
        let now = Date()
        if state["closed"] as? Bool == true {
            store.clear()
            return
        }
        guard let startedAtMs = state["startedAt"] as? Double else {
            store.clear()
            return
        }
        let startedAt = Date(timeIntervalSince1970: startedAtMs / 1000)
        if now.timeIntervalSince(startedAt) > Self.stateMaxAge {
            store.clear()
            return
        }
        let attempts = state["recoveryAttempts"] as? Int ?? 0
        if attempts >= Self.recoveryMaxAttempts {
            store.clear()
            return
        }
        let lockUntilMs = state["recoveryLockUntil"] as? Double ?? 0
        if lockUntilMs > now.timeIntervalSince1970 * 1000 { return }

        let owner = UUID().uuidString
        state["recoveryAttempts"] = attempts + 1
        state["recoveryLockOwner"] = owner
        state["recoveryLockUntil"] = now.addingTimeInterval(Self.recoveryLockSeconds).timeIntervalSince1970 * 1000
        state["updatedAt"] = now.timeIntervalSince1970 * 1000
        store.write(state)
        guard store.read()?["recoveryLockOwner"] as? String == owner else { return }

        let status: SessionStatus = (state["status"] as? String) == SessionStatus.crashed.wireValue ? .crashed : .abnormal
        let updatedAtMs = state["updatedAt"] as? Double ?? now.timeIntervalSince1970 * 1000
        let body: [String: Any?] = [
            "sessionId": state["sessionId"],
            "durationMs": max(0, Int(updatedAtMs - startedAtMs)),
            "status": status.wireValue,
        ]
        if transportEnabled {
            sender(Self.pathEnd, body)
        }
        state["status"] = status.wireValue
        state["closed"] = true
        state["endedAt"] = now.timeIntervalSince1970 * 1000
        state["recoveredAt"] = now.timeIntervalSince1970 * 1000
        state["recoveryLockUntil"] = 0
        store.write(state)
    }

    private func writeOpenState(_ session: Session, userId: String?) {
        var state: [String: Any] = [
            "version": Self.stateVersion,
            "sessionId": session.id,
            "startedAt": session.startedAt.timeIntervalSince1970 * 1000,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "status": session.status.wireValue,
            "release": release,
            "sdkName": sdkName,
            "sdkVersion": sdkVersion,
            "platform": platform,
            "closed": false,
        ]
        if let environment { state["environment"] = environment }
        if let userId { state["userId"] = userId }
        stateStore?.write(state)
    }

    private func writeClosedState(_ session: Session, status: SessionStatus) {
        var state: [String: Any] = [
            "version": Self.stateVersion,
            "sessionId": session.id,
            "startedAt": session.startedAt.timeIntervalSince1970 * 1000,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "status": status.wireValue,
            "release": release,
            "sdkName": sdkName,
            "sdkVersion": sdkVersion,
            "platform": platform,
            "closed": true,
            "endedAt": Date().timeIntervalSince1970 * 1000,
        ]
        if let environment { state["environment"] = environment }
        stateStore?.write(state)
    }
}

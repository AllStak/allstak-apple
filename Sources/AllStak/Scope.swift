import Foundation

/// A user associated with captured events. Mirrors the backend
/// `ErrorIngestRequest.UserContext` (`id` / `email` / `ip`); `username` is kept
/// SDK-side for parity with Sentry-cocoa but is not part of the wire contract.
public struct AllStakUser: Codable, Sendable, Equatable {
    public var id: String?
    public var email: String?
    public var ip: String?
    /// SDK-side only (Sentry-cocoa parity). Not part of the backend
    /// `UserContext` wire contract, so it is intentionally not encoded.
    public var username: String?

    public init(id: String? = nil, email: String? = nil, ip: String? = nil, username: String? = nil) {
        self.id = id
        self.email = email
        self.ip = ip
        self.username = username
    }

    // Only id/email/ip cross the wire; `username` stays SDK-side.
    private enum CodingKeys: String, CodingKey { case id, email, ip }

    /// `true` when no field carries a value (so the encoder can omit it).
    var isEmpty: Bool {
        id == nil && email == nil && ip == nil && username == nil
    }
}

/// One breadcrumb — a trail entry leading up to an event. Field names match the
/// backend `ErrorIngestRequest.BreadcrumbItem` (`timestamp` / `type` / `category`
/// / `message` / `level` / `data`). `timestamp` is an ISO-8601 string for
/// cross-SDK consistency (the JS SDK uses `new Date().toISOString()`).
public struct AllStakBreadcrumb: Codable, Sendable, Equatable {
    public let timestamp: String
    public let type: String
    public let category: String?
    public let message: String?
    public let level: String?
    public let data: [String: JSONValue]?

    public init(timestamp: String, type: String, category: String?,
                message: String?, level: String?, data: [String: JSONValue]?) {
        self.timestamp = timestamp
        self.type = type
        self.category = category
        self.message = message
        self.level = level
        self.data = data
    }
}

/// Sentry-cocoa-style scope: thread-safe, holds the contextual data attached to
/// captured events — a breadcrumb ring buffer, the active user, tags, named
/// contexts, free-form extra, a level override, and a fingerprint.
///
/// Mirrors the JS SDK's `Scope` semantics: dictionaries merge key-by-key
/// (later wins), the breadcrumb buffer is FIFO with a hard cap. All mutation is
/// guarded by an internal lock so a capture on another thread reads a consistent
/// snapshot. Fail-open throughout — nothing here ever throws into the host app.
public final class Scope: @unchecked Sendable {

    /// Default breadcrumb ring-buffer capacity (Sentry-cocoa default).
    public static let defaultMaxBreadcrumbs = 100

    private let lock = NSLock()
    private let maxBreadcrumbs: Int

    private var _breadcrumbs: [AllStakBreadcrumb] = []
    private var _user: AllStakUser?
    private var _tags: [String: String] = [:]
    private var _contexts: [String: [String: JSONValue]] = [:]
    private var _extra: [String: JSONValue] = [:]
    private var _level: String?
    private var _fingerprint: [String]?

    public init(maxBreadcrumbs: Int = Scope.defaultMaxBreadcrumbs) {
        self.maxBreadcrumbs = max(0, maxBreadcrumbs)
    }

    // MARK: Breadcrumbs

    /// Append a breadcrumb. When the buffer is at capacity the oldest entry is
    /// dropped first (FIFO ring buffer). A `maxBreadcrumbs` of 0 disables them.
    func addBreadcrumb(_ crumb: AllStakBreadcrumb) {
        guard maxBreadcrumbs > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        _breadcrumbs.append(crumb)
        if _breadcrumbs.count > maxBreadcrumbs {
            _breadcrumbs.removeFirst(_breadcrumbs.count - maxBreadcrumbs)
        }
    }

    /// Snapshot copy of the current breadcrumb trail (oldest first).
    var breadcrumbs: [AllStakBreadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return _breadcrumbs
    }

    func clearBreadcrumbs() {
        lock.lock(); defer { lock.unlock() }
        _breadcrumbs.removeAll()
    }

    // MARK: User

    func setUser(_ user: AllStakUser?) {
        lock.lock(); defer { lock.unlock() }
        _user = user
    }

    var user: AllStakUser? {
        lock.lock(); defer { lock.unlock() }
        return _user
    }

    // MARK: Tags

    func setTag(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        _tags[key] = value
    }

    func setTags(_ tags: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in tags { _tags[k] = v }
    }

    func removeTag(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        _tags[key] = nil
    }

    var tags: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return _tags
    }

    // MARK: Contexts

    /// Set (or, with `nil`, remove) a named context block.
    func setContext(_ key: String, _ value: [String: JSONValue]?) {
        lock.lock(); defer { lock.unlock() }
        if let value { _contexts[key] = value } else { _contexts[key] = nil }
    }

    var contexts: [String: [String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return _contexts
    }

    // MARK: Extra

    func setExtra(_ key: String, _ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        _extra[key] = value
    }

    func setExtras(_ extras: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in extras { _extra[k] = v }
    }

    var extra: [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _extra
    }

    // MARK: Level / fingerprint

    func setLevel(_ level: String?) {
        lock.lock(); defer { lock.unlock() }
        _level = level
    }

    var level: String? {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    func setFingerprint(_ fingerprint: [String]?) {
        lock.lock(); defer { lock.unlock() }
        _fingerprint = (fingerprint?.isEmpty == false) ? fingerprint : nil
    }

    var fingerprint: [String]? {
        lock.lock(); defer { lock.unlock() }
        return _fingerprint
    }

    // MARK: Clear / clone / merge

    func clear() {
        lock.lock(); defer { lock.unlock() }
        _breadcrumbs.removeAll()
        _user = nil
        _tags.removeAll()
        _contexts.removeAll()
        _extra.removeAll()
        _level = nil
        _fingerprint = nil
    }

    /// A deep copy used by `withScope` so mutations inside the callback never
    /// leak into the shared global scope.
    func clone() -> Scope {
        lock.lock(); defer { lock.unlock() }
        let copy = Scope(maxBreadcrumbs: maxBreadcrumbs)
        copy._breadcrumbs = _breadcrumbs
        copy._user = _user
        copy._tags = _tags
        copy._contexts = _contexts
        copy._extra = _extra
        copy._level = _level
        copy._fingerprint = _fingerprint
        return copy
    }

    /// Immutable snapshot of everything attached to an event, taken under one
    /// lock so the captured view is internally consistent.
    struct Snapshot {
        let breadcrumbs: [AllStakBreadcrumb]
        let user: AllStakUser?
        let tags: [String: String]
        let contexts: [String: [String: JSONValue]]
        let extra: [String: JSONValue]
        let level: String?
        let fingerprint: [String]?
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            breadcrumbs: _breadcrumbs,
            user: (_user?.isEmpty == false) ? _user : nil,
            tags: _tags,
            contexts: _contexts,
            extra: _extra,
            level: _level,
            fingerprint: _fingerprint)
    }
}

// MARK: - Public ergonomic API
//
// The internal methods above take wire-typed values (`JSONValue`). These public
// wrappers accept the friendlier `Any` / `[String: Any]` the host app uses, so
// `configureScope { scope in ... }` and `withScope { scope in ... }` are usable
// from outside the module. They are intentionally thin — all locking lives in
// the internal methods.
public extension Scope {

    /// Valid breadcrumb types (mirrors the JS SDK allowlist). Anything else is
    /// normalised to `default`.
    private static let validBreadcrumbTypes: Set<String> = [
        "default", "debug", "error", "navigation", "http", "info", "query",
        "transaction", "ui", "user",
    ]

    /// Record a breadcrumb. The timestamp is filled in here (ISO-8601 UTC) and an
    /// unknown `type` is normalised to `default`.
    func addBreadcrumb(type: String = "default", message: String? = nil,
                       category: String? = nil, level: String? = nil,
                       data: [String: Any]? = nil) {
        let normalizedType = Self.validBreadcrumbTypes.contains(type) ? type : "default"
        addBreadcrumb(AllStakBreadcrumb(
            timestamp: BreadcrumbClock.now(),
            type: normalizedType,
            category: category,
            message: message,
            level: level,
            data: data?.asJSONValueMap()))
    }

    func setUser(id: String? = nil, email: String? = nil,
                 ip: String? = nil, username: String? = nil) {
        setUser(AllStakUser(id: id, email: email, ip: ip, username: username))
    }

    func clearUser() { setUser(nil) }

    func setTag(key: String, value: String) { setTag(key, value) }

    /// Set (or, with `nil`, remove) a named context block from `[String: Any]`.
    func setContext(_ key: String, value: [String: Any]?) {
        setContext(key, value?.asJSONValueMap())
    }

    func setExtra(key: String, value: Any?) { setExtra(key, JSONValue(value)) }

    func setExtras(_ extras: [String: Any]) { setExtras(extras.asJSONValueMap()) }

    func setLevel(_ level: String) { setLevel(Optional(level)) }

    func setFingerprint(_ fingerprint: [String]) { setFingerprint(Optional(fingerprint)) }

    /// Clear everything on the scope.
    func clearAll() { clear() }
}

/// ISO-8601 timestamp string for a breadcrumb, matching the JS SDK's
/// `new Date().toISOString()` (UTC, millisecond precision). Allocated lazily and
/// reused; `ISO8601DateFormatter` is thread-safe for formatting.
enum BreadcrumbClock {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func now() -> String { formatter.string(from: Date()) }
}

import Foundation

/// One captured stack frame. For native Apple frames the symbol is resolved
/// server-side from the uploaded dSYM, so `instructionAddr` (runtime address) +
/// the event's `debugMeta.images` are what matter; `function` carries the raw
/// symbol when the OS already provides one.
public struct AllStakFrame: Codable, Sendable {
    public let function: String?
    public let filename: String?
    /// Runtime instruction address, hex. Consumed by the backend dSYM path.
    public let instructionAddr: String?
    public let inApp: Bool
}

public struct AllStakDebugMeta: Codable, Sendable {
    public let images: [AllStakBinaryImage]
}

/// The error event sent to `POST /ingest/v1/errors`. Field names match the
/// backend `ErrorIngestRequest` (Jackson camelCase); unknown fields are ignored
/// by the backend, so address fields are forward-compatible.
///
/// The scope fields (`breadcrumbs` / `user` / `tags` / `contexts` / `metadata`)
/// are optional and are OMITTED from the JSON when empty/nil so the wire shape is
/// byte-for-byte unchanged when scope is unused. `extra` is carried under the
/// backend's `metadata` field (where the JS SDK also puts free-form extra).
public struct AllStakErrorEvent: Codable, Sendable {
    public let exceptionClass: String
    public let message: String
    public let level: String
    public let platform: String        // "cocoa"
    public let environment: String?
    public let release: String?
    /// Release-health session this event belongs to. The backend's error
    /// consumer marks the session errored/crashed from this id. `nil` when
    /// session tracking is disabled.
    public let sessionId: String?
    public let frames: [AllStakFrame]
    public let debugMeta: AllStakDebugMeta
    public let sdkName: String
    public let sdkVersion: String
    public let timestamp: Double

    // ── Scope (additive, optional; omitted from JSON when empty) ───────────
    public var breadcrumbs: [AllStakBreadcrumb]?
    public var user: AllStakUser?
    public var tags: [String: String]?
    public var contexts: [String: [String: JSONValue]]?
    /// Free-form extra, wired under the backend `metadata` field.
    public var extra: [String: JSONValue]?
    public var fingerprint: [String]?

    public init(exceptionClass: String, message: String, level: String, platform: String,
                environment: String?, release: String?, sessionId: String?,
                frames: [AllStakFrame], debugMeta: AllStakDebugMeta,
                sdkName: String, sdkVersion: String, timestamp: Double,
                breadcrumbs: [AllStakBreadcrumb]? = nil, user: AllStakUser? = nil,
                tags: [String: String]? = nil,
                contexts: [String: [String: JSONValue]]? = nil,
                extra: [String: JSONValue]? = nil, fingerprint: [String]? = nil) {
        self.exceptionClass = exceptionClass
        self.message = message
        self.level = level
        self.platform = platform
        self.environment = environment
        self.release = release
        self.sessionId = sessionId
        self.frames = frames
        self.debugMeta = debugMeta
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.timestamp = timestamp
        self.breadcrumbs = breadcrumbs
        self.user = user
        self.tags = tags
        self.contexts = contexts
        self.extra = extra
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case exceptionClass, message, level, platform, environment, release
        case sessionId, frames, debugMeta, sdkName, sdkVersion, timestamp
        case breadcrumbs, user, tags, contexts, fingerprint
        // `extra` rides on the backend's `metadata` field.
        case extra = "metadata"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exceptionClass, forKey: .exceptionClass)
        try c.encode(message, forKey: .message)
        try c.encode(level, forKey: .level)
        try c.encode(platform, forKey: .platform)
        try c.encodeIfPresent(environment, forKey: .environment)
        try c.encodeIfPresent(release, forKey: .release)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(frames, forKey: .frames)
        try c.encode(debugMeta, forKey: .debugMeta)
        try c.encode(sdkName, forKey: .sdkName)
        try c.encode(sdkVersion, forKey: .sdkVersion)
        try c.encode(timestamp, forKey: .timestamp)

        // Omit scope fields entirely when empty so the existing wire shape is
        // preserved for events that carry no scope.
        if let breadcrumbs, !breadcrumbs.isEmpty { try c.encode(breadcrumbs, forKey: .breadcrumbs) }
        if let user, !user.isEmpty { try c.encode(user, forKey: .user) }
        if let tags, !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        if let contexts, !contexts.isEmpty { try c.encode(contexts, forKey: .contexts) }
        if let extra, !extra.isEmpty { try c.encode(extra, forKey: .extra) }
        if let fingerprint, !fingerprint.isEmpty { try c.encode(fingerprint, forKey: .fingerprint) }
    }
}

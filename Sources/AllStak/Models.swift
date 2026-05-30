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

/// One span item sent to `POST /ingest/v1/spans`.
///
/// The model mirrors the backend `SpanIngestRequest.SpanItem` shape and keeps
/// identifiers W3C-compatible before encoding: `traceId` is 32 lowercase hex
/// and `spanId`/`parentSpanId` are 16 lowercase hex. Optional empty values are
/// omitted so callers can emit only the fields they know.
public struct AllStakSpan: Codable, Sendable {
    public let traceId: String
    public let spanId: String
    public let parentSpanId: String?
    public let operation: String
    public let description: String?
    public let status: String
    public let durationMs: Int
    public let startTimeMillis: Int64
    public let endTimeMillis: Int64
    public let service: String?
    public let environment: String?
    public let tags: [String: JSONValue]?
    public let data: String?
    public let release: String?
    public let sessionId: String?
    public let op: String?
    public let platform: String?
    public let attributes: [String: JSONValue]?

    public init(traceId: String,
                spanId: String,
                parentSpanId: String? = nil,
                operation: String,
                description: String? = nil,
                status: String = "ok",
                durationMs: Int,
                startTimeMillis: Int64,
                endTimeMillis: Int64,
                service: String? = nil,
                environment: String? = nil,
                tags: [String: Any]? = nil,
                data: String? = nil,
                release: String? = nil,
                sessionId: String? = nil,
                op: String? = nil,
                platform: String? = nil,
                attributes: [String: Any]? = nil) {
        self.traceId = TracePropagation.normalizeTraceId(traceId)
        self.spanId = TracePropagation.normalizeSpanId(spanId)
        self.parentSpanId = parentSpanId.map { TracePropagation.normalizeSpanId($0) }
        self.operation = operation.isEmpty ? "span" : operation
        self.description = description
        self.status = status.isEmpty ? "ok" : status
        self.durationMs = max(0, durationMs)
        self.startTimeMillis = startTimeMillis
        self.endTimeMillis = endTimeMillis
        self.service = service
        self.environment = environment
        self.tags = tags?.asJSONValueMap()
        self.data = data
        self.release = release
        self.sessionId = sessionId
        self.op = op
        self.platform = platform
        self.attributes = attributes?.asJSONValueMap()
    }

    init(traceId: String,
         spanId: String,
         parentSpanId: String? = nil,
         operation: String,
         description: String? = nil,
         status: String = "ok",
         durationMs: Int,
         startTimeMillis: Int64,
         endTimeMillis: Int64,
         service: String? = nil,
         environment: String? = nil,
         tags: [String: JSONValue]? = nil,
         data: String? = nil,
         release: String? = nil,
         sessionId: String? = nil,
         op: String? = nil,
         platform: String? = nil,
         attributes: [String: JSONValue]? = nil) {
        self.traceId = TracePropagation.normalizeTraceId(traceId)
        self.spanId = TracePropagation.normalizeSpanId(spanId)
        self.parentSpanId = parentSpanId.map { TracePropagation.normalizeSpanId($0) }
        self.operation = operation.isEmpty ? "span" : operation
        self.description = description
        self.status = status.isEmpty ? "ok" : status
        self.durationMs = max(0, durationMs)
        self.startTimeMillis = startTimeMillis
        self.endTimeMillis = endTimeMillis
        self.service = service
        self.environment = environment
        self.tags = tags
        self.data = data
        self.release = release
        self.sessionId = sessionId
        self.op = op
        self.platform = platform
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey {
        case traceId, spanId, parentSpanId, operation, description, status
        case durationMs, startTimeMillis, endTimeMillis, service, environment
        case tags, data, release, sessionId, op, platform, attributes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(traceId, forKey: .traceId)
        try c.encode(spanId, forKey: .spanId)
        if let parentSpanId, !parentSpanId.isEmpty {
            try c.encode(parentSpanId, forKey: .parentSpanId)
        }
        try c.encode(operation, forKey: .operation)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(startTimeMillis, forKey: .startTimeMillis)
        try c.encode(endTimeMillis, forKey: .endTimeMillis)
        try c.encodeIfPresent(service, forKey: .service)
        try c.encodeIfPresent(environment, forKey: .environment)
        if let tags, !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(data, forKey: .data)
        try c.encodeIfPresent(release, forKey: .release)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(op, forKey: .op)
        try c.encodeIfPresent(platform, forKey: .platform)
        if let attributes, !attributes.isEmpty {
            try c.encode(attributes, forKey: .attributes)
        }
    }
}

struct AllStakSpanBatch: Codable, Sendable {
    let spans: [AllStakSpan]
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
    /// Event time, seconds since epoch. Mutable so a synthetic event (e.g. a
    /// watchdog termination inferred on the next launch) can be stamped to the
    /// time the originating run actually died, not the time we report it.
    public var timestamp: Double

    /// Distinguishes how the event was produced when it is NOT an ordinary
    /// handled error / crash — e.g. `"app_hang"` (main-thread unresponsive) or
    /// `"watchdog_termination"` (inferred OOM / watchdog kill on the prior
    /// launch). `nil` for ordinary errors and crashes (the common case), so the
    /// field is omitted from the JSON and the existing wire shape is preserved.
    /// The backend treats it as a forward-compatible optional discriminator.
    public var mechanism: String?

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
                mechanism: String? = nil,
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
        self.mechanism = mechanism
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
        case mechanism
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
        // Omit `mechanism` for ordinary errors/crashes so the existing wire shape
        // is byte-for-byte unchanged; present only for app-hang / watchdog events.
        try c.encodeIfPresent(mechanism, forKey: .mechanism)

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

import Foundation

/// Privacy-safe SDK diagnostics. Contains counters and sizes only, never
/// telemetry payloads, headers, user fields, breadcrumbs, or request bodies.
public struct AllStakDiagnostics: Sendable, Equatable {
    public var eventsCaptured: Int
    public var eventsSent: Int
    public var eventsFailed: Int
    public var eventsDropped: Int
    public var eventsPersisted: Int
    public var eventsReplayed: Int
    public var queueSize: Int
    public var retryAttempts: Int
    public var rateLimitedCount: Int
    public var compressedPayloads: Int
    public var uncompressedPayloads: Int
    public var compressionBytesSaved: Int
    public var sanitizerRedactionCount: Int?
    public var activeTraceCount: Int
    public var activeSpanCount: Int
    public var breadcrumbCount: Int
    public var sessionRecoveryCount: Int
    public var disabled: Bool

    public init(eventsCaptured: Int = 0,
                eventsSent: Int = 0,
                eventsFailed: Int = 0,
                eventsDropped: Int = 0,
                eventsPersisted: Int = 0,
                eventsReplayed: Int = 0,
                queueSize: Int = 0,
                retryAttempts: Int = 0,
                rateLimitedCount: Int = 0,
                compressedPayloads: Int = 0,
                uncompressedPayloads: Int = 0,
                compressionBytesSaved: Int = 0,
                sanitizerRedactionCount: Int? = nil,
                activeTraceCount: Int = 0,
                activeSpanCount: Int = 0,
                breadcrumbCount: Int = 0,
                sessionRecoveryCount: Int = 0,
                disabled: Bool = false) {
        self.eventsCaptured = eventsCaptured
        self.eventsSent = eventsSent
        self.eventsFailed = eventsFailed
        self.eventsDropped = eventsDropped
        self.eventsPersisted = eventsPersisted
        self.eventsReplayed = eventsReplayed
        self.queueSize = queueSize
        self.retryAttempts = retryAttempts
        self.rateLimitedCount = rateLimitedCount
        self.compressedPayloads = compressedPayloads
        self.uncompressedPayloads = uncompressedPayloads
        self.compressionBytesSaved = compressionBytesSaved
        self.sanitizerRedactionCount = sanitizerRedactionCount
        self.activeTraceCount = activeTraceCount
        self.activeSpanCount = activeSpanCount
        self.breadcrumbCount = breadcrumbCount
        self.sessionRecoveryCount = sessionRecoveryCount
        self.disabled = disabled
    }
}

struct TransportStats: Sendable, Equatable {
    var eventsSent: Int = 0
    var eventsFailed: Int = 0
    var eventsDropped: Int = 0
    var eventsPersisted: Int = 0
    var eventsReplayed: Int = 0
    var retryAttempts: Int = 0
    var rateLimitedCount: Int = 0
    var compressedPayloads: Int = 0
    var uncompressedPayloads: Int = 0
    var compressionBytesSaved: Int = 0
    var queueSize: Int = 0
    var disabled: Bool = false
}

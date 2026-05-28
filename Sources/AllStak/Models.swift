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
}

import Foundation

/// Status snapshot of a realtime voice connection. Mirrors the swift-realtime-openai
/// SDK's status surface but decoupled so RishiVoice consumers never import
/// `RealtimeAPI`. Plan 10-03's `RealtimeVoiceSession` actor reads this enum;
/// the production adapter maps the SDK type into it.
public enum RealtimeConnectionStatus: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// Role attached to a transcript fragment.
public enum TranscriptRole: String, Sendable, Equatable {
    case user
    case assistant
}

/// One transcript fragment surfaced by the SDK. `isFinal=true` indicates the
/// model marked the turn complete — Plan 10-04's `VoiceTranscriptBridge`
/// persists final fragments into `MessageStore`.
public struct RealtimeTranscriptEvent: Sendable, Equatable {
    public let role: TranscriptRole
    public let content: String
    public let isFinal: Bool
    public let timestamp: Date

    public init(
        role: TranscriptRole,
        content: String,
        isFinal: Bool,
        timestamp: Date = Date()
    ) {
        self.role = role
        self.content = content
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

/// Error surface for the realtime client. Mirrors the SDK's `ServerError`
/// shape (code + message) without leaking the SDK type.
public struct RealtimeClientError: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Seam isolating `RealtimeVoiceSession` (Plan 10-03) from the
/// `swift-realtime-openai` SDK. Production impl: `RealtimeAPIAdapter`.
/// Test impl: `FakeRealtimeClient`.
///
/// The protocol intentionally exposes a narrow surface — open + close +
/// status snapshot + two streams. Audio capture/playback is owned by the
/// SDK internally (WebRTC peer connection); RishiVoice never sees PCM
/// frames directly. Transcript events are the only conversation-layer
/// data that crosses this boundary.
public protocol RealtimeClientAPI: Sendable {
    /// Open a WebRTC voice session with the given ephemeral key. Throws on
    /// negotiation failure (network, key rejected, SDP failure).
    func connect(ephemeralKey: String) async throws

    /// Tear down the WebRTC session. Idempotent — calling on an already-closed
    /// client is a no-op.
    func disconnect() async

    /// Snapshot of the current connection status. Async because actor-isolated
    /// impls need a hop; SDK-backed impl reads `Conversation.status` directly.
    func currentStatus() async -> RealtimeConnectionStatus

    /// Server-side error stream. Finishes when the client disconnects.
    func errorStream() -> AsyncStream<RealtimeClientError>

    /// Transcript-event stream. Finishes when the client disconnects.
    func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent>
}

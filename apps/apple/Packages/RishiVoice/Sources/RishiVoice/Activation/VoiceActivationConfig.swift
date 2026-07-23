import Foundation

/// Tunables for the voice activation / PCM handoff path.
public struct VoiceActivationConfig: Sendable, Equatable {
    public var hangoverMs: Int
    public var maxBufferSeconds: Int
    public var handoffTimeoutMs: Int
    /// Max wait for end-of-speech before inject when user spoke during connect.
    public var silenceBoundaryTimeoutMs: Int
    public var appendChunkMs: Int

    public init(
        hangoverMs: Int = 700,
        maxBufferSeconds: Int = 8,
        handoffTimeoutMs: Int = 15_000,
        silenceBoundaryTimeoutMs: Int = 2_000,
        appendChunkMs: Int = 100
    ) {
        self.hangoverMs = hangoverMs
        self.maxBufferSeconds = maxBufferSeconds
        self.handoffTimeoutMs = handoffTimeoutMs
        self.silenceBoundaryTimeoutMs = silenceBoundaryTimeoutMs
        self.appendChunkMs = appendChunkMs
    }

    public static let `default` = VoiceActivationConfig()
}

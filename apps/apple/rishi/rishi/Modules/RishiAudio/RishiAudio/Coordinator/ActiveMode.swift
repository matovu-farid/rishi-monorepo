import Foundation

/// Which subsystem currently owns the shared AVAudioSession.
///
/// The `AudioSessionCoordinator` actor (TTS-08) flips between modes when
/// the user starts read-aloud (`.tts`) or opens voice chat (`.voice`).
/// Two consumers requesting the same mode is idempotent; a consumer
/// requesting a DIFFERENT mode tears down the previous configuration first.
public enum ActiveMode: String, Sendable, Equatable, CaseIterable {
    case idle
    case tts
    case voice
}

import Foundation

/// Chrome-facing activity hint for the reader voice pill. Derived from session
/// status and transcript events in v1; may later incorporate output audio level.
public enum VoiceActivityPhase: Sendable, Equatable {
    case connecting
    case listening
    case speaking
    case reconnecting
}

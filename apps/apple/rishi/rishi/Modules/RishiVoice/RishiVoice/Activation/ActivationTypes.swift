import Foundation

/// Legacy transport result retained for test doubles that model buffered input.
/// Production voice sessions do not create or use an activation/VAD pipeline.
public enum HandoffInjectPath: String, Sendable, Equatable {
    case path0A
    case path0B
    case path0C
}

public enum HandoffAcceptance: Sendable, Equatable {
    case accepted(path: HandoffInjectPath)
    case rejected(path: HandoffInjectPath, code: String)
    case ambiguous
    case noSpeech
}

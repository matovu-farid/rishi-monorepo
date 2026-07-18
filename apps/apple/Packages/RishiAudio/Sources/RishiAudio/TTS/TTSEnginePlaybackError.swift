import Foundation

/// Errors for engine-owned `TTSPlaying.waitUntilFinished` completion.
public enum TTSEnginePlaybackError: Error, Equatable, Sendable {
    /// Finish fired without a matching `didStart` / first buffer for this generation.
    case finishedWithoutPlaying
    /// Playback failed (stream, decode, or player).
    case playbackFailed(String)
}

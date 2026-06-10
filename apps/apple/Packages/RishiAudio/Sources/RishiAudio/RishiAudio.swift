import Foundation

/// RishiAudio — Feature-layer package owning the TTS / Read Aloud playback
/// surface (Phase 8) and the shared `AudioSessionCoordinator` actor used by
/// both TTS (Phase 8) and Voice Chat (Phase 10).
///
/// Phase 8 lands:
///   - AudioSessionCoordinator (TTS-08)
///   - TTSEngine + TTSStreamer + MP3StreamDecoder (TTS-01 / TTS-02)
///   - NowPlayingController + interruption handling (TTS-03 / TTS-04 / TTS-05)
///   - TTSPassageTracker (TTS-06)
///   - TTSSettings + TTSSettingsStore (TTS-07)
///   - ReadAloudControlsView + VoiceAndSpeedPicker (TTS-07 UI)
///
/// Depends DOWN on RishiCore (models), RishiAPI (SpeechStreamEndpoint +
/// WorkerClient), RishiAuth (AuthService for userId), RishiUIKit (tokens),
/// RishiLogging (os.Logger). Has NO dependency on RishiReader, RishiSync,
/// or RishiLibrary — reader integration lives in the rishi/ app layer.
public enum RishiAudio {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    public static let version = "0.2.0-coordinator-settings"
}

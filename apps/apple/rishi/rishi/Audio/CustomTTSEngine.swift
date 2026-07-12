import Foundation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore

/// Readium's TTS engine backed directly by the app's remote speech pipeline.
///
/// The app owns this type because it owns the worker-backed `TTSPlaying`
/// engine, persisted voice settings, and user identity. Readium still owns
/// publication iteration and invokes this engine one utterance at a time.
final class CustomTTSEngine: ReadiumNavigator.TTSEngine {

    let availableVoices: [TTSVoice]

    private let player: any TTSPlaying
    private let state: TTSPlaybackState
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID

    init(
        player: any TTSPlaying,
        state: TTSPlaybackState,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        voices: [TTSVoice] = CustomTTSEngine.defaultVoices
    ) {
        self.player = player
        self.state = state
        self.settingsStore = settingsStore
        self.userId = userId
        self.availableVoices = voices
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        do {
            try Task.checkCancellation()

            let voice: TTSVoice
            switch utterance.voiceOrLanguage {
            case let .left(requestedVoice):
                voice = requestedVoice
            case let .right(language):
                guard let matchingVoice = availableVoices
                    .filterByLanguage(language)
                    .sorted()
                    .first
                else {
                    return .failure(.languageNotSupported(language: language, cause: nil))
                }
                voice = matchingVoice
            }

            if utterance.delay > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(utterance.delay * 1_000_000_000)
                )
            }

            let settings = await settingsStore.load(userId: userId)
            let request = TTSStreamRequest(
                text: utterance.text,
                voice: voice.identifier,
                model: settings.model,
                speed: settings.speed
            )

            // The remote stream does not expose word-level timing. Mark the
            // whole Readium paragraph active while its audio is playing.
            onSpeakRange(utterance.text.startIndex..<utterance.text.endIndex)

            try await withTaskCancellationHandler {
                await player.start(request: request)
                try await waitForPlaybackToFinish()
            } onCancel: {
                Task { await player.stop() }
            }

            return .success(())
        } catch {
            return .failure(.other(error))
        }
    }

    private func waitForPlaybackToFinish() async throws {
        while true {
            try Task.checkCancellation()

            let snapshot = await MainActor.run {
                (state.status, state.error)
            }
            switch snapshot.0 {
            case .stopped:
                return
            case .error:
                throw RemoteTTSError(
                    message: snapshot.1 ?? "Remote TTS playback failed"
                )
            case .idle, .loading, .playing, .paused:
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private static let defaultVoices: [TTSVoice] = VoiceCatalog.all.map { identifier in
        TTSVoice(
            identifier: identifier,
            language: Language("en"),
            name: VoiceCatalog.displayName(for: identifier),
            gender: .unspecified,
            quality: .high
        )
    }
}

private struct RemoteTTSError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

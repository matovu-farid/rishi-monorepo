import Foundation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore
import RishiLogging

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
        // Readium's TTSUtterance has no public initializer; tests call the
        // component overload below. Production still enters through this path.
        await speak(
            text: utterance.text,
            delay: utterance.delay,
            voiceOrLanguage: utterance.voiceOrLanguage,
            onSpeakRange: onSpeakRange
        )
    }

    /// Speak entry that does not require constructing Readium's `TTSUtterance`
    /// (memberwise init is internal to ReadiumNavigator).
    func speak(
        text: String,
        delay: TimeInterval,
        voiceOrLanguage: Either<TTSVoice, Language>,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, TTSError> {
        do {
            try Task.checkCancellation()

            let voice: TTSVoice
            switch voiceOrLanguage {
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

            if delay > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }

            let settings = await settingsStore.load(userId: userId)

            // The remote stream does not expose word-level timing. Mark the
            // whole Readium paragraph active while its audio is playing.
            onSpeakRange(text.startIndex..<text.endIndex)

            let textPrefix = String(text.prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
            let startedAt = ContinuousClock.now
            let statusAtSpeakEntry = await MainActor.run { state.status.rawValue }

            // Worker rejects text above TTS_MAX_CHARS_PER_REQUEST. Long EPUB
            // paragraphs must be split or play fails with http_400 and used
            // to advance as if the utterance succeeded.
            let pieces = Self.requestPieces(for: text)
            Log.event("tts.readaloud.speak.begin", data: [
                "textLen": String(text.count),
                "textPrefix": textPrefix,
                "statusAtEntry": statusAtSpeakEntry,
                "pieceCount": String(pieces.count),
            ])

            try await withTaskCancellationHandler {
                for (index, piece) in pieces.enumerated() {
                    try Task.checkCancellation()
                    let request = TTSStreamRequest(
                        text: piece,
                        voice: voice.identifier,
                        model: settings.model,
                        speed: settings.speed
                    )
                    let piecePrefix = String(piece.prefix(60))
                        .replacingOccurrences(of: "\n", with: " ")
                    Log.event("tts.readaloud.speak.piece", data: [
                        "index": String(index),
                        "textLen": String(piece.count),
                        "textPrefix": piecePrefix,
                    ])
                    await player.start(request: request)
                    try await player.waitUntilFinished()
                }
            } onCancel: {
                Task { await player.stop() }
            }

            let elapsedMs = Int(startedAt.duration(to: .now) / .milliseconds(1))
            let statusAtEnd = await MainActor.run { state.status.rawValue }
            Log.event("tts.readaloud.speak.end", data: [
                "textLen": String(text.count),
                "textPrefix": textPrefix,
                "elapsedMs": String(elapsedMs),
                "statusAtEnd": statusAtEnd,
                "result": "success",
                "pieceCount": String(pieces.count),
            ])

            return .success(())
        } catch {
            let message = String(describing: error)
            Log.event("tts.readaloud.speak.end", level: .error, data: [
                "result": "failure",
                "error": message,
            ])
            return .failure(.other(error))
        }
    }

    /// Matches `workers/worker` `TTS_MAX_CHARS_PER_REQUEST`.
    private static let maxCharsPerRequest = 4000

    private static func requestPieces(for text: String) -> [String] {
        guard text.count > maxCharsPerRequest else { return [text] }
        let pieces = ParagraphChunker.chunk(text, maxChars: maxCharsPerRequest)
        return pieces.isEmpty ? [text] : pieces
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

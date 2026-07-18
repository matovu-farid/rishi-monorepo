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

            // The remote stream does not expose word-level timing. Mark the
            // whole Readium paragraph active while its audio is playing.
            onSpeakRange(utterance.text.startIndex..<utterance.text.endIndex)

            let textPrefix = String(utterance.text.prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
            let startedAt = ContinuousClock.now
            let statusAtSpeakEntry = await MainActor.run { state.status.rawValue }

            // Worker rejects text above TTS_MAX_CHARS_PER_REQUEST. Long EPUB
            // paragraphs must be split or play fails with http_400 and used
            // to advance as if the utterance succeeded.
            let pieces = Self.requestPieces(for: utterance.text)
            Log.event("tts.readaloud.speak.begin", data: [
                "textLen": String(utterance.text.count),
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
                    try await waitForPlaybackToFinish(
                        textPrefix: piecePrefix,
                        startedAt: ContinuousClock.now
                    )
                }
            } onCancel: {
                Task { await player.stop() }
            }

            let elapsedMs = Int(startedAt.duration(to: .now) / .milliseconds(1))
            let statusAtEnd = await MainActor.run { state.status.rawValue }
            Log.event("tts.readaloud.speak.end", data: [
                "textLen": String(utterance.text.count),
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

    private func waitForPlaybackToFinish(
        textPrefix: String,
        startedAt: ContinuousClock.Instant
    ) async throws {
        // Ignore residual `.stopped` from a prior utterance (cache-hit starts
        // used to leave status uncleared). Only treat `.stopped` as completion
        // after this utterance has been observed as `.loading` / `.playing`.
        //
        // WARNING: ReadAloudController also writes `.playing` onto this same
        // state when the synthesizer starts an utterance (before audio), so
        // hasStarted can become true from the synthesizer, not the engine.
        var hasStarted = false
        var sawEngineLoading = false
        var sawEnginePlaying = false
        while true {
            try Task.checkCancellation()

            let snapshot = await MainActor.run {
                (state.status, state.error)
            }
            switch snapshot.0 {
            case .loading:
                hasStarted = true
                sawEngineLoading = true
                try await Task.sleep(nanoseconds: 50_000_000)
            case .playing:
                hasStarted = true
                sawEnginePlaying = true
                try await Task.sleep(nanoseconds: 50_000_000)
            case .stopped:
                if hasStarted {
                    // Stream/player failures can briefly land on `.stopped`
                    // before `.error`. Never treat a failed utterance as success.
                    if let error = snapshot.1, !error.isEmpty {
                        throw RemoteTTSError(message: error)
                    }
                    // Ended during loading without ever playing — almost always
                    // an empty/failed stream. Advancing would skip the paragraph.
                    if sawEngineLoading && !sawEnginePlaying {
                        throw RemoteTTSError(
                            message: "TTS ended before playback started"
                        )
                    }
                    let elapsedMs = Int(startedAt.duration(to: .now) / .milliseconds(1))
                    Log.event("tts.readaloud.speak.stopped", data: [
                        "textPrefix": textPrefix,
                        "elapsedMs": String(elapsedMs),
                        "sawLoading": sawEngineLoading ? "1" : "0",
                        "sawPlaying": sawEnginePlaying ? "1" : "0",
                    ])
                    return
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            case .error:
                throw RemoteTTSError(
                    message: snapshot.1 ?? "Remote TTS playback failed"
                )
            case .idle, .paused:
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

import Foundation
import ReadiumNavigator
import ReadiumShared




/// Readium's TTS engine backed directly by the app's remote speech pipeline.
///
/// The app owns this type because it owns the worker-backed `TTSPlaying`
/// engine, persisted voice settings, and user identity. Readium still owns
/// publication iteration and invokes this engine one utterance at a time.
final class CustomTTSEngine: ReadiumNavigator.TTSEngine, @unchecked Sendable {

    let availableVoices: [TTSVoice]

    private let player: any TTSPlaying
    private let state: TTSPlaybackState
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID
    private let sessionToken: UUID
    private let onUtteranceFinished: (@Sendable () async -> Void)?
    private let onUtteranceFailed: (@Sendable () async -> Void)?

    init(
        player: any TTSPlaying,
        state: TTSPlaybackState,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        sessionToken: UUID = UUID(),
        voices: [TTSVoice] = CustomTTSEngine.defaultVoices,
        onUtteranceFinished: (@Sendable () async -> Void)? = nil,
        onUtteranceFailed: (@Sendable () async -> Void)? = nil
    ) {
        self.player = player
        self.state = state
        self.settingsStore = settingsStore
        self.userId = userId
        self.sessionToken = sessionToken
        self.onUtteranceFinished = onUtteranceFinished
        self.onUtteranceFailed = onUtteranceFailed
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
        var activeTokens: TTSPlaybackTokenSnapshot?
        let cancellationStop = CancellationStopGate()
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
                    await onUtteranceFailed?()
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

            let startedAt = ContinuousClock.now
            let statusAtSpeakEntry = await MainActor.run { state.status.rawValue }

            // Worker rejects text above TTS_MAX_CHARS_PER_REQUEST. Long EPUB
            // paragraphs must be split or play fails with http_400 and used
            // to advance as if the utterance succeeded.
            let pieces = ParagraphChunker.chunkForTTS(
                text,
                maxChars: Self.maxCharsPerRequest
            )
            let utteranceToken = UUID()
            Log.event("tts.readaloud.speak.begin", data: [
                "textLen": String(text.count),
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
                        speed: settings.speed,
                        sessionToken: sessionToken,
                        utteranceToken: utteranceToken,
                        requestToken: UUID()
                    )
                    activeTokens = request.tokenSnapshot
                    await cancellationStop.setCurrent(request.tokenSnapshot)
                    Log.event("tts.readaloud.speak.piece", data: [
                        "index": String(index),
                        "textLen": String(piece.count),
                    ])
                    let lease = TTSAlwaysValidLease()
                    await player.start(request: request, lease: lease)
                    try await player.waitUntilFinished(lease: lease)
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await cancellationStop.startIfNeeded(using: player) }
            }

            await onUtteranceFinished?()

            let elapsedMs = Int(startedAt.duration(to: .now) / .milliseconds(1))
            let statusAtEnd = await MainActor.run { state.status.rawValue }
            Log.event("tts.readaloud.speak.end", data: [
                "textLen": String(text.count),
                "elapsedMs": String(elapsedMs),
                "statusAtEnd": statusAtEnd,
                "result": "success",
                "pieceCount": String(pieces.count),
            ])

            return .success(())
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            if wasCancelled {
                // The cancellation handler starts the stop asynchronously. Do
                // not let Readium observe this utterance as finished until the
                // underlying player has completed stopping; otherwise the next
                // utterance can race the old player's teardown.
                await cancellationStop.wait(using: player)
            }
            if !wasCancelled {
                await onUtteranceFailed?()
            }
            if let allowance = error as? WorkerAllowanceError,
               let activeTokens {
                await MainActor.run {
                    state.recordTypedFailure(allowance, tokens: activeTokens)
                }
            } else if let userFacingError = TTSUserFacingError.classify(error) {
                await MainActor.run {
                    state.recordUserFacingFailure(userFacingError)
                }
            }
            Log.error(
                "tts.readaloud.speak.end",
                error: error,
                diagnostic: TelemetryDiagnostic(
                    feature: "tts",
                    operation: "tts.readaloud.speak",
                    stage: "playback",
                    errorCode: TTSUserFacingError.classify(error)?.rawValue ?? "playback_failed",
                    fields: ["request_chars": String(text.count)]
                )
            )
            return .failure(.other(error))
        }
    }

    /// Matches `workers/worker` `TTS_MAX_CHARS_PER_REQUEST`.
    private static let maxCharsPerRequest = 4000

    private nonisolated(unsafe) static let defaultVoices: [TTSVoice] = VoiceCatalog.all.map { identifier in
        TTSVoice(
            identifier: identifier,
            language: Language("en"),
            name: VoiceCatalog.displayName(for: identifier),
            gender: .unspecified,
            quality: .high
        )
    }
}

private actor CancellationStopGate {
    private var stopTask: Task<Void, Never>?
    private var currentTokens: TTSPlaybackTokenSnapshot?

    func setCurrent(_ tokens: TTSPlaybackTokenSnapshot) {
        currentTokens = tokens
    }

    func startIfNeeded(using player: any TTSPlaying) {
        guard stopTask == nil, let currentTokens else { return }
        let lease = TTSAlwaysValidLease()
        stopTask = Task { await player.stop(ifCurrent: currentTokens, lease: lease) }
    }

    func wait(using player: any TTSPlaying) async {
        startIfNeeded(using: player)
        await stopTask?.value
    }
}

import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared





private func makeReadiumEngineFactory(
    player: any TTSPlaying,
    state: TTSPlaybackState,
    settingsStore: any TTSSettingsStore,
    userId: UserID,
    sessionToken: UUID
) -> PublicationSpeechSynthesizer.EngineFactory {
    {
        CustomTTSEngine(
            player: player,
            state: state,
            settingsStore: settingsStore,
            userId: userId,
            sessionToken: sessionToken
        )
    }
}

private func makeReadiumTokenizerFactory(
    granularity: CustomTTSTokenizer.Granularity,
    selectionText: Locator.Text? = nil
) -> PublicationSpeechSynthesizer.TokenizerFactory {
    var didTrimSelection = false
    return { language in
        let tokenizer = CustomTTSTokenizer.tokenize(
            defaultLanguage: language,
            granularity: granularity
        )
        return { content in
            if !didTrimSelection, let selectionText {
                if let trimmed = CustomTTSTokenizer.trimming(
                    content,
                    before: selectionText
                ) {
                    didTrimSelection = true
                    return try tokenizer(trimmed)
                }
                // Do not consume the one-shot trim while Readium is still
                // yielding a non-text element before the selected passage.
                if content is TextualContentElement {
                    didTrimSelection = true
                }
            }
            return try tokenizer(content)
        }
    }
}


@MainActor
@Observable
final class ReadAloudController {

    private let ttsEngine: any TTSPlaying
    private let ttsState: TTSPlaybackState
    private let ttsSettingsStore: any TTSSettingsStore
    private let ttsPrewarmer: TTSPrewarmer
    private let ttsPresence: TTSPresenceController
    private let userId: UserID
    private let nowPlayingController: NowPlayingController?
    private let bookFileStorage: BookFileStorage?
    private let onAllowanceFailure: (@MainActor (WorkerAllowanceError) -> Void)?
    private var typedFailureObserverID: UUID?
    private var typedFailureObserverGeneration: UInt64 = 0
    private var isDisposed = false

    private(set) var bridge: ReaderTTSBridge? = nil
    private(set) var readiumSynthesizer: PublicationSpeechSynthesizer? = nil
    private var readiumSynthesizerGeneration: UInt64?
    private(set) var readiumState: PublicationSpeechSynthesizer.State = .stopped
    /// Readium's pause API cancels and recreates the current utterance. Keep
    /// its task alive and pause the shared player directly so resume continues
    /// from the current audio position.
    private var isReadiumPlaybackPaused = false
    private var readiumPublication: Publication?
    private var readiumPrefetcher: ReadiumTTSPrefetchCoordinator?
    private var hasStartedReadAloudSession = false
    private var isPageEntryPrefetchEligible = false
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil
    private(set) var currentLocator: Locator? = nil
    private var coordinator: AudioSessionCoordinator
    /// Monotonic utterance counter for skip diagnostics (`tts.readaloud.utterance`).
    private var utteranceSeq = 0
    private var lastLoggedUtteranceText: String?
    /// At most one credit-consuming page-follow per spoken utterance.
    private var followCreditRemaining = 0
    private var navigationIntentGeneration: UInt64 = 0
    /// Invalidates work suspended while a playback session is starting. This
    /// prevents a cancelled/replaced start from attaching Now Playing controls
    /// or starting a synthesizer after one of its prerequisite awaits returns.
    private var playbackGeneration: UInt64 = 0
    private var playbackSessionToken: UUID?
    private var keyboardParagraphNavigationTask: Task<Void, Never>?
    private var keyboardParagraphNavigationGeneration: UInt64 = 0
    private var keyboardParagraphNavigationTaskID: UInt64 = 0
    private var playbackTeardownDepth = 0

    private var isStoppingPlayback: Bool {
        playbackTeardownDepth > 0
    }

    var keyboardParagraphNavigationGenerationForCallbacks: UInt64 {
        keyboardParagraphNavigationGeneration
    }
    private(set) var wantsAutoResumeAfterVoice = false
    /// Test seam: force `isActivelySpeaking` without a live synthesizer.
    #if DEBUG
    private var testSpeakingOverride = false
    #endif

    init(
        ttsEngine: any TTSPlaying,
        ttsState: TTSPlaybackState,
        ttsSettingsStore: any TTSSettingsStore,
        ttsPrewarmer: TTSPrewarmer,
        ttsPresence: TTSPresenceController,
        coordidator: AudioSessionCoordinator,
        userId: UserID,
        nowPlayingController: NowPlayingController? = nil,
        bookFileStorage: BookFileStorage? = nil,
        onAllowanceFailure: (@MainActor (WorkerAllowanceError) -> Void)? = nil
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.ttsPrewarmer = ttsPrewarmer
        self.ttsPresence = ttsPresence
        self.userId = userId
        self.coordinator = coordidator
        self.nowPlayingController = nowPlayingController
        self.bookFileStorage = bookFileStorage
        self.onAllowanceFailure = onAllowanceFailure
        installTypedFailureObserver()
    }

    func startReader(vm: ReaderViewModel) async {
        await startReader(vm: vm, startLocator: nil)
    }

    func startReader(vm: ReaderViewModel, from startLocator: Locator) async {
        await startReader(vm: vm, startLocator: startLocator)
    }

    private func startReader(
        vm: ReaderViewModel,
        startLocator explicitStartLocator: Locator?
    ) async {
        isDisposed = false
        installTypedFailureObserver()
        guard let publication = vm.publication else { return }
        let generation = beginPlaybackGeneration()

        // Invalidate page-entry prefetch immediately while the new playback
        // session is being installed. The await below must not leave the old
        // stopped session eligible during this transition.
        isPageEntryPrefetchEligible = false
        await stopCurrentPlayback()
        guard isCurrentPlaybackGeneration(generation) else { return }
        let sessionToken = UUID()
        playbackSessionToken = sessionToken

        let settings = await ttsSettingsStore.load(userId: userId)
        guard isCurrentPlaybackGeneration(generation) else { return }
        pickerInitial = settings
        let tokenizerGranularity: CustomTTSTokenizer.Granularity =
            vm.book.formatType == .pdf || publication.manifest.conforms(to: .pdf)
            ? .sentence
            : .paragraph
        let engineFactory = makeReadiumEngineFactory(
            player: ttsEngine,
            state: ttsState,
            settingsStore: ttsSettingsStore,
            userId: userId,
            sessionToken: sessionToken
        )
        let tokenizerFactory = makeReadiumTokenizerFactory(
            granularity: tokenizerGranularity,
            selectionText: explicitStartLocator?.text
        )

        guard let synthesizer = PublicationSpeechSynthesizer(
            publication: publication,
            config: .init(
                defaultLanguage: publication.metadata.language,
                voiceIdentifier: settings.voice
            ),
            engineFactory: engineFactory,
            tokenizerFactory: tokenizerFactory,
            delegate: self
        ) else {
            return
        }

        readiumSynthesizer = synthesizer
        readiumSynthesizerGeneration = generation
        hasStartedReadAloudSession = true
        readiumPublication = publication
        readiumPrefetcher = ReadiumTTSPrefetchCoordinator(
            prewarmer: ttsPrewarmer,
            granularity: tokenizerGranularity
        )
        readiumState = .stopped
        currentParagraph = nil
        currentLocator = nil
        paragraphs = []
        utteranceSeq = 0
        lastLoggedUtteranceText = nil
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        showControls = true

        await registerTTSPreemption()
        guard isCurrentPlaybackGeneration(generation) else { return }
        await ttsPresence.beginSession(
            bookID: vm.book.id.uuidString,
            title: vm.book.title,
            author: vm.book.author,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
        guard isCurrentPlaybackGeneration(generation) else { return }

        // Readium's locationDidChange callback can lag behind the visible
        // page during an animated EPUB turn. Query the navigator-backed live
        // locator immediately before starting so playback cannot rewind to
        // the last callback's page.
        let startLocator: Locator?
        if let explicitStartLocator {
            startLocator = explicitStartLocator
        } else {
            startLocator = await vm.currentVisibleLocatorForReadAloud()
        }
        guard isCurrentPlaybackGeneration(generation) else { return }

        // Readium owns publication iteration. The custom tokenizer supplied
        // above keeps EPUB utterances paragraph-scoped and uses sentence
        // utterances for PDF playback.
        await activateAudioSessionForReadiumStart()
        guard isCurrentPlaybackGeneration(generation) else { return }
        attachNowPlayingImmediately(
            title: vm.book.title,
            author: vm.book.author,
            book: vm.book,
            playbackRate: settings.speed,
            generation: generation
        )
        // Attach metadata before the first utterance. The cover is loaded
        // best-effort in a separate task so local disk I/O cannot delay speech.
        synthesizer.start(from: startLocator)
    }

    func stop() async {
        invalidatePlaybackGeneration()
        isPageEntryPrefetchEligible = true
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        await stopCurrentPlayback()
        await ttsPresence.endSession()
        showControls = false
        showPicker = false
        paragraphs = []
        currentParagraph = nil
        currentLocator = nil
    }

    /// Whether speech is in flight (Readium utterance or legacy bridge).
    /// Used for page-turn intent: only then can a swipe mean "follow paragraph".
    var isActivelySpeaking: Bool {
        guard !isStoppingPlayback else { return false }
        #if DEBUG
        if testSpeakingOverride { return true }
        #endif
        if case .playing = readiumState, !isReadiumPlaybackPaused { return true }
        if bridge != nil, ttsState.status == .playing { return true }
        return false
    }

    /// Starts a user-navigation intent and snapshots spoken state for that swipe.
    @discardableResult
    func beginUserNavigationIntent() -> ReadAloudUserNavigationSnapshot {
        navigationIntentGeneration &+= 1
        return ReadAloudUserNavigationSnapshot(
            generation: navigationIntentGeneration,
            isActivelySpeaking: isActivelySpeaking,
            spokenParagraph: currentParagraph,
            spokenPage: currentLocator?.locations.page,
            followCreditRemaining: followCreditRemaining
        )
    }

    /// Resolves page-turn intent for `snapshot.generation`. Returns `nil` when superseded.
    func resolveUserNavigationIntent(
        snapshot: ReadAloudUserNavigationSnapshot,
        destinationParagraphs: [String],
        destinationPage: Int?
    ) -> ReadAloudUserNavigationIntent? {
        guard snapshot.generation == navigationIntentGeneration else {
            Log.event("tts.nav.intent", data: [
                "generation": String(snapshot.generation),
                "result": "stale",
                "creditAfter": String(followCreditRemaining),
            ])
            return nil
        }
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: snapshot.isActivelySpeaking,
            spokenParagraph: snapshot.spokenParagraph,
            destinationParagraphs: destinationParagraphs,
            spokenPage: snapshot.spokenPage,
            destinationPage: destinationPage,
            followCreditRemaining: snapshot.followCreditRemaining
        )
        switch intent {
        case .continuePlaying(consumesFollowCredit: true):
            // Only burn credit belonging to the snapshotted utterance. If the
            // utterance advanced during extract, live credit was refilled for
            // the new text — leave it alone.
            if lastLoggedUtteranceText == snapshot.spokenParagraph {
                followCreditRemaining = max(0, followCreditRemaining - 1)
            }
            Log.event("tts.nav.intent", data: [
                "generation": String(snapshot.generation),
                "result": "continue_consume",
                "creditAfter": String(followCreditRemaining),
            ])
        case .continuePlaying(consumesFollowCredit: false):
            Log.event("tts.nav.intent", data: [
                "generation": String(snapshot.generation),
                "result": "continue_same_page",
                "creditAfter": String(followCreditRemaining),
            ])
        case .stopPlaying:
            Log.event("tts.nav.intent", data: [
                "generation": String(snapshot.generation),
                "result": "stop",
                "creditAfter": String(followCreditRemaining),
            ])
        }
        return intent
    }

    #if DEBUG
    /// Test setup: speaking + paragraph/page + `followCreditRemaining = 1`.
    func simulateSpeakingForTests(paragraph: String, page: Int? = nil) {
        currentParagraph = paragraph
        lastLoggedUtteranceText = paragraph
        followCreditRemaining = 1
        testSpeakingOverride = true
        if let page, let href = RelativeURL(path: "publication.pdf") {
            currentLocator = Locator(
                href: href,
                mediaType: .pdf,
                locations: Locator.Locations(fragments: ["page=\(page)"])
            )
        } else {
            currentLocator = nil
        }
    }

    /// Production-equivalent: refill credit only if `text` != last spoken utterance text.
    func notifyUtterancePlayingForTests(text: String) {
        currentParagraph = text
        testSpeakingOverride = true
        guard text != lastLoggedUtteranceText else { return }
        lastLoggedUtteranceText = text
        followCreditRemaining = 1
    }
    #endif

    func togglePlayback() async {
        if readiumSynthesizer != nil {
            if isReadiumPlaybackPaused {
                await resumeReadiumPlayback()
            } else if case .playing = readiumState {
                await pauseReadiumPlayback()
            }
        } else if let bridge {
            if ttsState.status == .playing {
                isPageEntryPrefetchEligible = true
                await bridge.pause()
            } else {
                isPageEntryPrefetchEligible = false
                await bridge.resume()
            }
        }
        if ttsState.status == .paused {
            wantsAutoResumeAfterVoice = false
        }
    }

    /// Pauses an active read-aloud session before opening voice chat, preserving
    /// position for ``resumeAfterVoiceIfNeeded()`` when the user returns.
    func pauseForVoiceHandoff() async {
        let wasPlaying = ttsState.status == .playing || isActivelySpeaking
        guard wasPlaying else {
            wantsAutoResumeAfterVoice = false
            return
        }
        wantsAutoResumeAfterVoice = true
        if readiumSynthesizer != nil {
            await pauseReadiumPlayback()
        } else if let bridge {
            await bridge.pause()
        }
    }

    func resumeAfterVoiceIfNeeded() async {
        guard wantsAutoResumeAfterVoice else { return }
        wantsAutoResumeAfterVoice = false
        await togglePlayback()
    }

    func openReadAloudFromVoice(vm: ReaderViewModel) async {
        if wantsAutoResumeAfterVoice {
            await resumeAfterVoiceIfNeeded()
        } else {
            await startReader(vm: vm)
        }
    }

    private func registerTTSPreemption() async {
        await coordinator.registerPreemption(for: .tts) { [weak self] in
            await self?.pauseForVoiceHandoff()
        }
        await coordinator.registerSuspension(for: .tts) { [weak self] in
            await self?.pauseForSystemAudioEvent()
        }
    }

    /// System interruptions and output-route loss pause the active reader
    /// without marking it as a voice handoff (which would request auto-resume).
    private func pauseForSystemAudioEvent() async {
        guard isActivelySpeaking else { return }
        if readiumSynthesizer != nil {
            await pauseReadiumPlayback()
        } else {
            await bridge?.pause()
        }
    }

    private func pauseReadiumPlayback() async {
        guard !isReadiumPlaybackPaused,
              case .playing = readiumState
        else { return }

        await ttsEngine.pause()
        isReadiumPlaybackPaused = true
        isPageEntryPrefetchEligible = true
        ttsState.update(status: .paused)
    }

    private func resumeReadiumPlayback() async {
        guard isReadiumPlaybackPaused else { return }

        await ttsEngine.resume()
        isReadiumPlaybackPaused = false
        isPageEntryPrefetchEligible = false
        ttsState.update(status: .playing)
    }

    /// Claims the shared playback session before Readium starts delivering
    /// speech. Unlike the legacy bridge, Readium bypasses `ReaderTTSBridge`,
    /// so it must activate `.playback` / `.spokenAudio` itself.
    func activateAudioSessionForReadiumStart() async {
        await coordinator.requestActiveMode(.tts)
    }

    func previous() async {
        if let readiumSynthesizer {
            readiumSynthesizer.previous()
        } else {
            await bridge?.previous()
        }
    }

    func next() async {
        if let readiumSynthesizer {
            readiumSynthesizer.next()
        } else {
            await bridge?.next()
        }
    }

    func repeatCurrent() async {
        if let readiumSynthesizer, let currentLocator {
            await coordinator.requestActiveMode(.tts)
            readiumSynthesizer.start(from: currentLocator)
        } else {
            await bridge?.repeatCurrent()
        }
    }

    func applySettings(_ settings: TTSSettings) async {
        pickerInitial = settings
        await ttsSettingsStore.save(settings, userId: userId)
        readiumSynthesizer?.config.voiceIdentifier = settings.voice
        await readiumPrefetcher?.stop()
        await ttsPresence.updatePlaybackSettings(
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
    }

    /// Applies a speed selected by a system media surface. Keep this guard in
    /// the reader as well as in the command surface so invalid direct callers
    /// cannot persist unsupported values.
    func applyPlaybackRate(_ rate: Double) async {
        guard TTSSettings.speedPresets.contains(where: { abs($0 - rate) < 0.0001 }) else { return }
        guard abs(pickerInitial.speed - rate) >= 0.0001 else { return }
        await applySettings(TTSSettings(voice: pickerInitial.voice, model: pickerInitial.model, speed: rate))
    }

    func start(
        paragraphs: [String],
        startIndex: Int = 0,
        bookID: String,
        metadata: NowPlayingMetadata,
        book: Book? = nil,
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) async {
        isDisposed = false
        installTypedFailureObserver()
        guard !paragraphs.isEmpty else { return }
        let generation = beginPlaybackGeneration()

        isPageEntryPrefetchEligible = false
        await stopCurrentPlayback()
        guard isCurrentPlaybackGeneration(generation) else { return }
        let sessionToken = UUID()
        playbackSessionToken = sessionToken

        let wrappedOnParagraphsExhausted: () async -> [String] = { [weak self] in
            let nextParagraphs = await onParagraphsExhausted()
            if nextParagraphs.isEmpty {
                self?.isPageEntryPrefetchEligible = true
                self?.nowPlayingController?.detach()
            } else {
                self?.isPageEntryPrefetchEligible = false
            }
            return nextParagraphs
        }

        let tracker = TTSPassageTracker()
        let newBridge = ReaderTTSBridge(
            engine: ttsEngine,
            state: ttsState,
            tracker: tracker,
            prewarmer: ttsPrewarmer,
            settingsStore: ttsSettingsStore,
            userId: userId,
            coordinator: coordinator,
            onPassageChange: onPassageChange,
            onParagraphsExhausted: wrappedOnParagraphsExhausted,
            onParagraphsBeforeStart: onParagraphsBeforeStart,
            sessionToken: sessionToken
        )
        bridge = newBridge
        hasStartedReadAloudSession = true
        self.paragraphs = paragraphs
        currentParagraph = nil
        pickerInitial = await ttsSettingsStore.load(userId: userId)
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else { return }
        await ttsPresence.beginSession(
            bookID: bookID,
            title: metadata.title,
            author: metadata.author,
            voice: pickerInitial.voice,
            model: pickerInitial.model,
            speed: pickerInitial.speed
        )
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else { return }
        showControls = true
        await registerTTSPreemption()
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else { return }
        // Publish the system card before narration begins. Any cover stored on
        // disk is upgraded asynchronously after playback has started.
        attachNowPlayingImmediately(
            title: metadata.title,
            author: metadata.author,
            book: book,
            coverData: metadata.coverData,
            playbackRate: pickerInitial.speed,
            generation: generation
        )
        await newBridge.start(paragraphs: paragraphs, startIndex: startIndex)
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else { return }
    }

    var canPrefetchPageEntry: Bool {
        hasStartedReadAloudSession && isPageEntryPrefetchEligible
    }

    func prefetchFirstParagraph(_ paragraph: String?) async {
        guard canPrefetchPageEntry,
              let paragraph,
              !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let settings = await ttsSettingsStore.load(userId: userId)
        guard canPrefetchPageEntry else { return }

        let pieces = ParagraphChunker.chunkForTTS(
            paragraph,
            maxChars: ReadiumTTSPrefetchRequestBuilder.maxCharsPerRequest
        )
        await ttsPrewarmer.warm(requests: pieces.map {
            TTSStreamRequest(
                text: $0,
                voice: settings.voice,
                model: settings.model,
                speed: settings.speed,
                passageId: nil
            )
        })
    }

    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }

    private func teardownPlaybackSession(preservingFailure: Bool = false) async {
        playbackTeardownDepth += 1
        defer { playbackTeardownDepth -= 1 }

        let inFlightKeyboardNavigation = keyboardParagraphNavigationTask
        keyboardParagraphNavigationGeneration &+= 1
        keyboardParagraphNavigationTask?.cancel()
        keyboardParagraphNavigationTask = nil
        // A bridge navigation can be suspended inside the engine. Wait for it
        // to return before stopping the bridge so an old request cannot resume
        // and publish `.playing` after this teardown or a replacement session.
        await inFlightKeyboardNavigation?.value

        nowPlayingController?.detach()
        Log.event("tts.nav.stop", data: [
            "hadSynthesizer": readiumSynthesizer != nil ? "1" : "0",
            "lastSeq": String(max(0, utteranceSeq - 1)),
            "lastPrefix": lastLoggedUtteranceText.map { String($0.prefix(60)) } ?? "",
        ])
        await readiumPrefetcher?.stop()
        readiumPrefetcher = nil
        readiumPublication = nil
        isReadiumPlaybackPaused = false
        if let bridge {
            await bridge.stop()
            self.bridge = nil
        }
        readiumSynthesizer?.stop()
        readiumSynthesizer = nil
        readiumState = .stopped
        playbackSessionToken = nil
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        ttsState.endSession(preservingFailure: preservingFailure)
        // The controller owns the Readium lifecycle, so it releases the
        // coordinator only when a session actually stops—not between passages.
        await coordinator.releaseActiveMode(.tts)
    }

    private func stopCurrentPlayback() async {
        await teardownPlaybackSession()
    }

    private func handleTypedAllowanceFailure(
        _ failure: WorkerAllowanceError,
        tokens: TTSPlaybackTokenSnapshot,
        playbackGeneration: UInt64,
        observerGeneration: UInt64
    ) async {
        guard isValidTypedFailure(
            tokens: tokens,
            playbackGeneration: playbackGeneration,
            observerGeneration: observerGeneration
        ) else { return }

        // Keep the typed failure alive while the controller tears down the
        // Readium session. This prevents the generic alert from racing the
        // upgrade sheet and ensures the observer's signal survives teardown.
        await teardownPlaybackSession(preservingFailure: true)

        // Teardown yields to the engine. A replacement start or disposal may
        // have happened while it was suspended, so never show the prompt for
        // the session that the user has already moved away from.
        guard isValidTypedFailure(
            tokens: tokens,
            playbackGeneration: playbackGeneration,
            observerGeneration: observerGeneration,
            allowClearedState: true
        ) else { return }
        onAllowanceFailure?(failure)
        if !isDisposed { installTypedFailureObserver() }
    }

    private func installTypedFailureObserver() {
        guard !isDisposed, typedFailureObserverID == nil else { return }
        let observerGeneration = typedFailureObserverGeneration
        typedFailureObserverID = ttsState.observeTypedFailure { [weak self] failure, tokens in
            guard let self else { return }
            let playbackGeneration = self.playbackGeneration
            guard self.isValidTypedFailure(
                tokens: tokens,
                playbackGeneration: playbackGeneration,
                observerGeneration: observerGeneration
            ) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.isValidTypedFailure(
                          tokens: tokens,
                          playbackGeneration: playbackGeneration,
                          observerGeneration: observerGeneration
                      )
                else { return }
                await self.handleTypedAllowanceFailure(
                    failure,
                    tokens: tokens,
                    playbackGeneration: playbackGeneration,
                    observerGeneration: observerGeneration
                )
            }
        }
    }

    private func isValidTypedFailure(
        tokens: TTSPlaybackTokenSnapshot,
        playbackGeneration: UInt64,
        observerGeneration: UInt64,
        allowClearedState: Bool = false
    ) -> Bool {
        guard !isDisposed,
              typedFailureObserverID != nil,
              typedFailureObserverGeneration == observerGeneration,
              self.playbackGeneration == playbackGeneration
        else { return false }

        if allowClearedState {
            return playbackSessionToken == nil
                || playbackSessionToken == tokens.sessionToken
        }
        return playbackSessionToken == tokens.sessionToken
            && ttsState.typedFailureTokens == tokens
    }

    func dispose() {
        isDisposed = true
        typedFailureObserverGeneration &+= 1
        if let typedFailureObserverID {
            ttsState.removeTypedFailureObserver(typedFailureObserverID)
            self.typedFailureObserverID = nil
        }
    }

    private func beginPlaybackGeneration() -> UInt64 {
        playbackGeneration &+= 1
        return playbackGeneration
    }

    private func invalidatePlaybackGeneration() {
        playbackGeneration &+= 1
    }

    private func isCurrentPlaybackGeneration(_ generation: UInt64) -> Bool {
        playbackGeneration == generation
    }

    /// Attaches the immediately available metadata. Cover art comes from disk
    /// on a detached task and may update the card later, never delaying speech.
    private func attachNowPlayingImmediately(
        title: String,
        author: String?,
        book: Book?,
        coverData: Data? = nil,
        playbackRate: Double? = nil,
        generation: UInt64
    ) {
        guard isCurrentPlaybackGeneration(generation) else { return }
        let metadata = NowPlayingMetadata(
            title: title,
            author: author,
            coverData: coverData,
            playbackRate: playbackRate ?? 1.0,
            supportedPlaybackRates: TTSSettings.speedPresets
        )
        nowPlayingController?.attach(state: ttsState, controller: self, metadata: metadata)

        guard coverData == nil,
              let book,
              let bookFileStorage
        else { return }

        let coverURL = bookFileStorage.cachedCoverURLIfFresh(for: book)
        Task { [weak self, title, author] in
            let cachedCoverData: Data? = await Task.detached {
                guard let coverURL else { return nil }
                return try? Data(contentsOf: coverURL)
            }.value
            guard let self,
                  self.isCurrentPlaybackGeneration(generation),
                  let cachedCoverData
            else { return }
            // NowPlayingController intentionally has an attach-only API. A
            // short reattach preserves its handler ownership while refreshing
            // the metadata with best-effort artwork.
            self.nowPlayingController?.detach()
            guard self.isCurrentPlaybackGeneration(generation) else { return }
            self.nowPlayingController?.attach(
                state: self.ttsState,
                controller: self,
                metadata: NowPlayingMetadata(title: title, author: author, coverData: cachedCoverData)
            )
        }
    }

}

extension ReadAloudController: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        guard readiumSynthesizer === synthesizer else { return }
        guard let generation = readiumSynthesizerGeneration,
              isCurrentPlaybackGeneration(generation)
        else { return }

        readiumState = state
        switch state {
        case .stopped:
            invalidatePlaybackGeneration()
            nowPlayingController?.detach()
            isReadiumPlaybackPaused = false
            isPageEntryPrefetchEligible = true
            followCreditRemaining = 0
            #if DEBUG
            testSpeakingOverride = false
            #endif
            currentParagraph = nil
            currentLocator = nil
            ttsState.update(status: .stopped)
            // A Readium `.stopped` transition is terminal for its publication
            // synthesizer. Release the shared audio owner here, rather than
            // reacting to per-paragraph engine status changes.
            Task { [coordinator] in
                await coordinator.releaseActiveMode(.tts)
            }
        case let .paused(utterance):
            isPageEntryPrefetchEligible = true
            currentLocator = utterance.locator
            currentParagraph = utterance.text
            ttsState.update(status: .paused)
        case let .playing(utterance, range):
            isPageEntryPrefetchEligible = false
            currentLocator = range ?? utterance.locator
            currentParagraph = utterance.text
            // UI only: synthesizer lifecycle mirrors into ttsState for controls.
            // CustomTTSEngine completion uses TTSPlaying.waitUntilFinished — not this field.
            ttsState.update(status: .playing)
            logUtteranceIfNew(utterance)
            if let publication = readiumPublication {
                readiumPrefetcher?.update(
                    publication: publication,
                    utterance: utterance,
                    settings: pickerInitial
                )
            }
        }
    }

    private func logUtteranceIfNew(_ utterance: PublicationSpeechSynthesizer.Utterance) {
        guard utterance.text != lastLoggedUtteranceText else { return }
        lastLoggedUtteranceText = utterance.text
        followCreditRemaining = 1
        let seq = utteranceSeq
        utteranceSeq += 1
        let prefix = String(utterance.text.prefix(80))
            .replacingOccurrences(of: "\n", with: " ")
        Log.event("tts.readaloud.utterance", data: [
            "seq": String(seq),
            "href": utterance.locator.href.string,
            "css": utterance.locator.locations.cssSelector ?? "",
            "prog": utterance.locator.locations.progression.map { String(format: "%.4f", $0) } ?? "",
            "textLen": String(utterance.text.count),
            "textPrefix": prefix,
            "engineStatus": ttsState.status.rawValue,
        ])
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        guard readiumSynthesizer === synthesizer else { return }
        guard let generation = readiumSynthesizerGeneration,
              isCurrentPlaybackGeneration(generation)
        else { return }
        nowPlayingController?.detach()
        readiumState = .stopped
        if ttsState.typedFailure == nil {
            if let userFacingError = TTSUserFacingError.classify(error) {
                ttsState.recordUserFacingFailure(userFacingError)
            }
        }
        Task { [coordinator] in
            await coordinator.releaseActiveMode(.tts)
        }
    }
}

extension ReadAloudController: TTSPlaybackControlling {
    @MainActor
    func pause() async {
        guard ttsState.status == .playing || isActivelySpeaking else { return }
        await togglePlayback()
    }

    @MainActor
    func resume() async {
        guard ttsState.status == .paused else { return }
        await togglePlayback()
    }

    @MainActor
    func previousTrack() async {
        await previous()
    }

    @MainActor
    func nextTrack() async {
        await next()
    }

    @MainActor
    func changePlaybackRate(to rate: Double) async {
        await applyPlaybackRate(rate)
    }
}

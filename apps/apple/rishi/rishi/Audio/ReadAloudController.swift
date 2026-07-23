import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore
import RishiLibrary
import RishiLogging
import RishiReader

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

    private(set) var bridge: ReaderTTSBridge? = nil
    private(set) var readiumSynthesizer: PublicationSpeechSynthesizer? = nil
    private(set) var readiumState: PublicationSpeechSynthesizer.State = .stopped
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
        bookFileStorage: BookFileStorage? = nil
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
    }

    func startReader(vm: ReaderViewModel) async {
        guard let publication = vm.publication else { return }

        // Invalidate page-entry prefetch immediately while the new playback
        // session is being installed. The await below must not leave the old
        // stopped session eligible during this transition.
        isPageEntryPrefetchEligible = false
        await stopCurrentPlayback()

        let settings = await ttsSettingsStore.load(userId: userId)
        pickerInitial = settings

        guard let synthesizer = PublicationSpeechSynthesizer(
            publication: publication,
            config: .init(
                defaultLanguage: publication.metadata.language,
                voiceIdentifier: settings.voice
            ),
            engineFactory: { [ttsEngine, ttsState, ttsSettingsStore, userId] in
                CustomTTSEngine(
                    player: ttsEngine,
                    state: ttsState,
                    settingsStore: ttsSettingsStore,
                    userId: userId
                )
            },
            tokenizerFactory: { language in
                CustomTTSTokenizer.tokenize(defaultLanguage: language)
            },
            delegate: self
        ) else {
            return
        }

        readiumSynthesizer = synthesizer
        hasStartedReadAloudSession = true
        readiumPublication = publication
        readiumPrefetcher = ReadiumTTSPrefetchCoordinator(prewarmer: ttsPrewarmer)
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
        await ttsPresence.beginSession(
            bookID: vm.book.id.uuidString,
            title: vm.book.title,
            author: vm.book.author,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )

        // Readium's locationDidChange callback can lag behind the visible
        // page during an animated EPUB turn. Query the navigator-backed live
        // locator immediately before starting so playback cannot rewind to
        // the last callback's page.
        let startLocator = await vm.currentVisibleLocatorForReadAloud()

        // Readium owns publication iteration. The custom tokenizer supplied
        // above makes each utterance a paragraph instead of a sentence.
        synthesizer.start(from: startLocator)
        nowPlayingController?.attach(
            state: ttsState,
            controller: self,
            metadata: await nowPlayingMetadata(
                title: vm.book.title,
                author: vm.book.author,
                book: vm.book
            )
        )
    }

    func stop() async {
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
        #if DEBUG
        if testSpeakingOverride { return true }
        #endif
        if case .playing = readiumState { return true }
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
        if let readiumSynthesizer {
            isPageEntryPrefetchEligible = ttsState.status == .playing
            readiumSynthesizer.pauseOrResume()
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
        if let readiumSynthesizer {
            if case .playing = readiumState {
                readiumSynthesizer.pauseOrResume()
            }
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
        guard !paragraphs.isEmpty else { return }

        isPageEntryPrefetchEligible = false
        if let existing = bridge {
            await existing.stop()
        }
        nowPlayingController?.detach()

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
            onParagraphsBeforeStart: onParagraphsBeforeStart
        )
        bridge = newBridge
        hasStartedReadAloudSession = true
        self.paragraphs = paragraphs
        currentParagraph = nil
        pickerInitial = await ttsSettingsStore.load(userId: userId)
        await ttsPresence.beginSession(
            bookID: bookID,
            title: metadata.title,
            author: metadata.author,
            voice: pickerInitial.voice,
            model: pickerInitial.model,
            speed: pickerInitial.speed
        )
        showControls = true
        await registerTTSPreemption()
        await newBridge.start(paragraphs: paragraphs, startIndex: startIndex)
        nowPlayingController?.attach(
            state: ttsState,
            controller: self,
            metadata: await nowPlayingMetadata(
                title: metadata.title,
                author: metadata.author,
                book: book,
                coverData: metadata.coverData
            )
        )
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

        await ttsPrewarmer.warm(requests: [
            TTSStreamRequest(
                text: paragraph,
                voice: settings.voice,
                model: settings.model,
                speed: settings.speed,
                passageId: nil
            )
        ])
    }

    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }

    private func stopCurrentPlayback() async {
        nowPlayingController?.detach()
        Log.event("tts.nav.stop", data: [
            "hadSynthesizer": readiumSynthesizer != nil ? "1" : "0",
            "lastSeq": String(max(0, utteranceSeq - 1)),
            "lastPrefix": lastLoggedUtteranceText.map { String($0.prefix(60)) } ?? "",
        ])
        await readiumPrefetcher?.stop()
        readiumPrefetcher = nil
        readiumPublication = nil
        if let bridge {
            await bridge.stop()
            self.bridge = nil
        }
        readiumSynthesizer?.stop()
        readiumSynthesizer = nil
        readiumState = .stopped
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        ttsState.update(status: .stopped)
    }

    private func nowPlayingMetadata(
        title: String,
        author: String?,
        book: Book?,
        coverData: Data? = nil
    ) async -> NowPlayingMetadata {
        guard coverData == nil,
              let book,
              let bookFileStorage
        else {
            return NowPlayingMetadata(title: title, author: author, coverData: coverData)
        }

        let coverURL = bookFileStorage.cachedCoverURLIfFresh(for: book)
        let cachedCoverData: Data? = await Task.detached {
            guard let coverURL else { return nil }
            return try? Data(contentsOf: coverURL)
        }.value
        return NowPlayingMetadata(title: title, author: author, coverData: cachedCoverData)
    }
}

extension ReadAloudController: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        guard readiumSynthesizer === synthesizer else { return }

        readiumState = state
        switch state {
        case .stopped:
            nowPlayingController?.detach()
            isPageEntryPrefetchEligible = true
            followCreditRemaining = 0
            #if DEBUG
            testSpeakingOverride = false
            #endif
            currentParagraph = nil
            currentLocator = nil
            ttsState.update(status: .stopped)
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
        nowPlayingController?.detach()
        ttsState.error = String(describing: error)
        ttsState.update(status: .error)
    }
}

extension ReadAloudController: TTSPlaybackControlling {
    func pause() async {
        guard ttsState.status == .playing || isActivelySpeaking else { return }
        await togglePlayback()
    }

    func resume() async {
        guard ttsState.status == .paused else { return }
        await togglePlayback()
    }

    func previousTrack() async {
        await previous()
    }

    func nextTrack() async {
        await next()
    }
}

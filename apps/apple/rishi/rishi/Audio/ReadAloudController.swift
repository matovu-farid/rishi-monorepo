import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore
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

    init(
        ttsEngine: any TTSPlaying,
        ttsState: TTSPlaybackState,
        ttsSettingsStore: any TTSSettingsStore,
        ttsPrewarmer: TTSPrewarmer,
        ttsPresence: TTSPresenceController,
        coordidator: AudioSessionCoordinator,
        userId: UserID
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.ttsPrewarmer = ttsPrewarmer
        self.ttsPresence = ttsPresence
        self.userId = userId
        self.coordinator = coordidator
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
        showControls = true

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
    }

    func stop() async {
        isPageEntryPrefetchEligible = true
        await stopCurrentPlayback()
        await ttsPresence.endSession()
        showControls = false
        showPicker = false
        paragraphs = []
        currentParagraph = nil
        currentLocator = nil
    }

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
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) async {
        guard !paragraphs.isEmpty else { return }

        isPageEntryPrefetchEligible = false
        if let existing = bridge {
            await existing.stop()
        }

        let wrappedOnParagraphsExhausted: () async -> [String] = { [weak self] in
            let nextParagraphs = await onParagraphsExhausted()
            if nextParagraphs.isEmpty {
                self?.isPageEntryPrefetchEligible = true
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
        await newBridge.start(paragraphs: paragraphs, startIndex: startIndex)
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
        ttsState.update(status: .stopped)
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
            isPageEntryPrefetchEligible = true
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
            // NOTE: This writes the same TTSPlaybackState CustomTTSEngine waits
            // on. Synthesizer `.playing` can arrive before the audio engine
            // starts — keep this update, but utterance-order logs ignore
            // range-only repeats so we can detect real skips.
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
        ttsState.error = String(describing: error)
        ttsState.update(status: .error)
    }
}

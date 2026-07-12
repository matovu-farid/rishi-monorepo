import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore
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
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil
    private(set) var currentLocator: Locator? = nil
    private var coordinator: AudioSessionCoordinator

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
        readiumState = .stopped
        currentParagraph = nil
        currentLocator = nil
        paragraphs = []
        showControls = true

        await ttsPresence.beginSession(
            bookID: vm.book.id.uuidString,
            title: vm.book.title,
            author: vm.book.author,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )

        // Readium owns publication iteration. The custom tokenizer supplied
        // above makes each utterance a paragraph instead of a sentence.
        synthesizer.start(from: vm.latestLocator)
    }

    func stop() async {
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
            readiumSynthesizer.pauseOrResume()
        } else if let bridge {
            if ttsState.status == .playing {
                await bridge.pause()
            } else {
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

        if let existing = bridge {
            await existing.stop()
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
            onParagraphsExhausted: onParagraphsExhausted,
            onParagraphsBeforeStart: onParagraphsBeforeStart
        )
        bridge = newBridge
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

    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }

    private func stopCurrentPlayback() async {
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
            currentParagraph = nil
            currentLocator = nil
            ttsState.update(status: .stopped)
        case let .paused(utterance):
            currentLocator = utterance.locator
            currentParagraph = utterance.text
            ttsState.update(status: .paused)
        case let .playing(utterance, range):
            currentLocator = range ?? utterance.locator
            currentParagraph = utterance.text
            ttsState.update(status: .playing)
        }
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

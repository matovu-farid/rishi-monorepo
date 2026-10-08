import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared

enum ReadAloudLocalPlaybackPhase: Equatable {
    case noSession
    case playing(UUID)
    case paused(UUID)
}

enum ExplicitForwardPlaybackResult: Equatable {
    case restarted
    case alreadyReadingDestination
    case rejected
}

private struct ExplicitReadAloudForwardIntent {
    let id: UUID
    let playbackToken: UUID
    let playbackGeneration: UInt64
    let navigationGeneration: UInt64
    let spokenPage: Int?
    let utteranceEpoch: UInt64
}

/// A room's playback speed is temporary. Readium loads settings for every
/// utterance, so override reads here without modifying the user's preference.
private actor SharedSessionTTSSettingsStore: TTSSettingsStore {
    private let persisted: any TTSSettingsStore
    private var sharedRate: Double?
    private var sharedRateFence: SharedRateMutationFence?

    init(persisted: any TTSSettingsStore) {
        self.persisted = persisted
    }

    func load(userId: UserID) async -> TTSSettings {
        let settings = await persisted.load(userId: userId)
        guard let sharedRate else { return settings }
        return TTSSettings(voice: settings.voice, model: settings.model, speed: sharedRate)
    }

    func save(_ settings: TTSSettings, userId: UserID) async {
        await persisted.save(settings, userId: userId)
    }

    func save(_ settings: TTSSettings, userId: UserID, lease: any TTSMutationLease) async {
        await persisted.save(settings, userId: userId, lease: lease)
    }

    func remove(userId: UserID) async {
        await persisted.remove(userId: userId)
    }

    func setSharedRate(_ rate: Double, fence: SharedRateMutationFence) -> Bool {
        guard canAdvance(to: fence) else { return false }
        sharedRateFence = fence
        let changed = sharedRate.map({ abs($0 - rate) >= 0.0001 }) ?? true
        sharedRate = rate
        return changed
    }

    func clearSharedRate(fence: SharedRateMutationFence) -> Bool {
        guard sharedRateFence?.scopeID == fence.scopeID, canAdvance(to: fence) else { return false }
        sharedRateFence = fence
        sharedRate = nil
        return true
    }

    private func canAdvance(to fence: SharedRateMutationFence) -> Bool {
        guard let current = sharedRateFence else { return true }
        return fence.revision > current.revision
    }
}





private func makeReadiumEngineFactory(
    player: any TTSPlaying,
    state: TTSPlaybackState,
    settingsStore: any TTSSettingsStore,
    userId: UserID,
    sessionToken: UUID,
    onUtteranceFinished: (@Sendable () async -> Void)? = nil,
    onUtteranceFailed: (@Sendable () async -> Void)? = nil
) -> PublicationSpeechSynthesizer.EngineFactory {
    {
        CustomTTSEngine(
            player: player,
            state: state,
            settingsStore: settingsStore,
            userId: userId,
            sessionToken: sessionToken,
            onUtteranceFinished: onUtteranceFinished,
            onUtteranceFailed: onUtteranceFailed
        )
    }
}

private func makeReadiumTokenizerFactory(
    granularity: CustomTTSTokenizer.Granularity,
    selectionText: Locator.Text? = nil,
    selectionStartPage: Int? = nil,
    selectionStartUTF16Offset: Int? = nil,
    pdfParagraphMap: PDFNarrationParagraphMap? = nil,
    pdfCursor: CustomTTSTokenizer.PDFNarrationTokenizationCursor? = nil,
    epubResumePlan: EPUBNarrationResumePlan? = nil
) -> PublicationSpeechSynthesizer.TokenizerFactory {
    if granularity == .sentence, let pdfParagraphMap {
        let selectionGate = pdfCursor == nil && selectionText != nil
            ? CustomTTSTokenizer.PDFNarrationSelectionGate(startingPage: selectionStartPage)
            : nil
        return { language in
            CustomTTSTokenizer.tokenizePDF(
                defaultLanguage: language,
                paragraphMap: pdfParagraphMap,
                cursor: pdfCursor,
                selectionText: pdfCursor == nil ? selectionText : nil,
                selectionStartUTF16Offset: pdfCursor == nil ? selectionStartUTF16Offset : nil,
                selectionGate: selectionGate
            )
        }
    }
    let selectionGate = EPUBNarrationSelectionGate(plan: epubResumePlan, fallbackSelection: selectionText)
    return { language in
        selectionGate.tokenizer(defaultLanguage: language, granularity: granularity)
    }
}


@MainActor
@Observable
final class ReadAloudController {

    private let ttsEngine: any TTSPlaying
    private let ttsState: TTSPlaybackState
    private let ttsSettingsStore: any TTSSettingsStore
    private let sharedSessionSettingsStore: SharedSessionTTSSettingsStore
    private let ttsPrewarmer: TTSPrewarmer
    private let ttsPresence: TTSPresenceController
    private let userId: UserID
    private let nowPlayingController: NowPlayingController?
    private let bookFileStorage: BookFileStorage?
    private let onAllowanceFailure: (@MainActor (WorkerAllowanceError, UUID) -> Void)?
    private let onReadAloudPositionChange: (@MainActor (Locator) -> Void)?
    private let onPersistReadAloudPosition: (@MainActor (Locator) async -> Void)?
    private var typedFailureObserverID: UUID?
    private var typedFailureObserverGeneration: UInt64 = 0
    private var isDisposed = false
    private var terminalPlaybackTeardownTask: Task<Void, Never>?
    private var terminalPlaybackTeardownIdentity: (session: UUID, generation: UInt64, id: UUID)?
    private(set) var requiresPlaybackRestart = false
    private var terminalFailureSessionToken: UUID?

    private(set) var bridge: ReaderTTSBridge? = nil
    private(set) var readiumSynthesizer: PublicationSpeechSynthesizer? = nil
    private var readiumSynthesizerGeneration: UInt64?
    private(set) var readiumState: PublicationSpeechSynthesizer.State = .stopped
    /// Readium's pause API cancels and recreates the current utterance. Keep
    /// its task alive and pause the shared player directly so resume continues
    /// from the current audio position.
    private var isReadiumPlaybackPaused = false
    private var readiumPublication: Publication?
    #if DEBUG
    var epubResumePlannerForTests: (@MainActor (Publication, Locator) async throws -> EPUBNarrationResumePlan?)?
    #endif
    private var readiumSynthesizerBuilder: (@MainActor (CustomTTSTokenizer.PDFNarrationTokenizationCursor?) -> PublicationSpeechSynthesizer?)?
    private var readiumRestartTarget: (page: Int, paragraphStart: Int?, utteranceOrdinal: Int?)?
    private var readiumRestartEpoch: UInt64 = 0
    @ObservationIgnored
    private lazy var pdfNarrationSequencer = PDFNarrationSequencer(
        isCurrent: { [weak self] request, expectedID in
            guard let self, let synthesizer = self.readiumSynthesizer else { return false }
            return (request.lease?.isValid ?? true)
                && request.playbackToken == self.playbackSessionToken
                && self.isCurrentPlaybackGeneration(request.playbackGeneration)
                && ObjectIdentifier(synthesizer) == expectedID
        },
        resolve: { [weak self] cursor, delta in
            await self?.resolvePDFUtteranceTarget(from: cursor, delta: delta)
        },
        apply: { [weak self] target, expectedID in
            self?.applyPDFUtteranceTarget(target, expectedSynthesizerID: expectedID)
        },
        stopAtEnd: { [weak self] lease in
            await self?.stop(preservingPosition: true, lease: lease)
        }
    )
    private var readiumPrefetcher: ReadiumTTSPrefetchCoordinator?
    private var hasStartedReadAloudSession = false
    private var isPageEntryPrefetchEligible = false
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil
    private(set) var currentLocator: Locator? = nil
    private var lastPlayingLocator: Locator?
    private var lastPlayingUtteranceText: String?
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
    private var readiumUtteranceEpoch: UInt64 = 0
    private var readiumEpochLocator: Locator?
    private var readiumEpochText: String?
    private var readiumObservedLocator: Locator?
    private var readiumObservedText: String?
    private var explicitReadAloudForwardIntent: ExplicitReadAloudForwardIntent?
    private weak var readerViewModel: ReaderViewModel?
    private var sharedFollowerResumeAnchor: Locator?
    private var sharedFollowerAudioRevision: SharedReadingEffectRevision?
    private var sharedFollowerAudioFence: SharedRateMutationFence?
    private var sharedRateMutationFence: SharedRateMutationFence?
    private var didNotifyFirstUtterance = false
    private var firstUtteranceGeneration: UInt64?
    var onFirstUtteranceFinished: (@MainActor () -> Void)?
    var onFirstUtteranceFailed: (@MainActor () -> Void)?
    var onPlaybackSessionInvalidated: (@MainActor () -> Void)?
    private var keyboardParagraphNavigationTask: Task<Void, Never>?
    private var keyboardParagraphNavigationGeneration: UInt64 = 0
    private var keyboardParagraphNavigationTaskID: UInt64 = 0
    private var playbackTeardownDepth = 0
    private var acceptsReadAloudPositionUpdates = true

    var localPlaybackPhase: ReadAloudLocalPlaybackPhase {
        guard hasActivePlaybackSession, let playbackSessionToken else { return .noSession }
        return isActivelySpeaking
            ? .playing(playbackSessionToken)
            : .paused(playbackSessionToken)
    }

    var effectivePlaybackRate: Double { pickerInitial.speed }
    var currentNarrationLocator: Locator? { sharedFollowerResumeAnchor ?? currentLocator }

    func invalidateSharedFollowerEffects(fence: SharedRateMutationFence) {
        guard fence.revision > (sharedFollowerAudioFence?.revision ?? 0),
              fence.revision > (sharedRateMutationFence?.revision ?? 0) else { return }
        sharedFollowerAudioFence = fence
        sharedFollowerAudioRevision = nil
        sharedRateMutationFence = fence
    }

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
        onAllowanceFailure: (@MainActor (WorkerAllowanceError, UUID) -> Void)? = nil,
        onReadAloudPositionChange: (@MainActor (Locator) -> Void)? = nil,
        onPersistReadAloudPosition: (@MainActor (Locator) async -> Void)? = nil,
        onFirstUtteranceFinished: (@MainActor () -> Void)? = nil,
        onFirstUtteranceFailed: (@MainActor () -> Void)? = nil
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.sharedSessionSettingsStore = SharedSessionTTSSettingsStore(persisted: ttsSettingsStore)
        self.ttsPrewarmer = ttsPrewarmer
        self.ttsPresence = ttsPresence
        self.userId = userId
        self.coordinator = coordidator
        self.nowPlayingController = nowPlayingController
        self.bookFileStorage = bookFileStorage
        self.onAllowanceFailure = onAllowanceFailure
        self.onReadAloudPositionChange = onReadAloudPositionChange
        self.onPersistReadAloudPosition = onPersistReadAloudPosition
        self.onFirstUtteranceFinished = onFirstUtteranceFinished
        self.onFirstUtteranceFailed = onFirstUtteranceFailed
        installTypedFailureObserver()
    }

    func startReader(vm: ReaderViewModel) async {
        await startReader(vm: vm, startLocator: nil)
    }

    func startReader(vm: ReaderViewModel, from startLocator: Locator) async {
        await startReader(vm: vm, startLocator: startLocator)
    }

    func startReader(vm: ReaderViewModel, from startLocator: Locator?, admission: ReadAloudStartAdmission) async {
        await startReader(vm: vm, startLocator: startLocator, admission: admission)
    }

    private func startReader(
        vm: ReaderViewModel,
        startLocator explicitStartLocator: Locator?,
        admission: ReadAloudStartAdmission? = nil
    ) async {
        func canStart() -> Bool { !Task.isCancelled && (admission?.isValid ?? true) }
        guard canStart() else { return }
        readerViewModel = vm
        sharedFollowerResumeAnchor = nil
        isDisposed = false
        installTypedFailureObserver()
        guard let publication = vm.publication else {
            onFirstUtteranceFailed?()
            return
        }
        let generation = beginPlaybackGeneration()
        await drainTerminalPlaybackTeardown()
        guard isCurrentPlaybackGeneration(generation), canStart() else { return }
        if let terminalFailureSessionToken {
            ttsState.clearPreservedFailure(ifCurrent: terminalFailureSessionToken)
        }
        acceptsReadAloudPositionUpdates = true

        // Invalidate page-entry prefetch immediately while the new playback
        // session is being installed. The await below must not leave the old
        // stopped session eligible during this transition.
        isPageEntryPrefetchEligible = false
        await stopCurrentPlayback()
        guard isCurrentPlaybackGeneration(generation), canStart() else { return }
        let sessionToken = UUID()

        let settings = await sharedSessionSettingsStore.load(userId: userId)
        guard isCurrentPlaybackGeneration(generation), canStart() else { return }
        pickerInitial = settings
        let startLocator = await vm.readAloudStartLocator(explicit: explicitStartLocator)
        guard isCurrentPlaybackGeneration(generation), canStart() else { return }
        let tokenizerGranularity: CustomTTSTokenizer.Granularity =
            vm.book.formatType == .pdf || publication.manifest.conforms(to: .pdf)
            ? .sentence
            : .paragraph
        let epubResumePlan: EPUBNarrationResumePlan?
        if tokenizerGranularity == .paragraph, let startLocator {
            let sourceAdmission: SourceEffectAdmission?
            do {
                sourceAdmission = try admitReaderSource(vm)
            } catch { return }
            defer { sourceAdmission?.release() }
            do {
                #if DEBUG
                if let planner = epubResumePlannerForTests {
                    epubResumePlan = try await planner(publication, startLocator)
                } else {
                    epubResumePlan = try await EPUBNarrationResumePlanner.prepare(publication: publication, from: startLocator)
                }
                #else
                epubResumePlan = try await EPUBNarrationResumePlanner.prepare(publication: publication, from: startLocator)
                #endif
            } catch { return }
        } else {
            epubResumePlan = nil
        }
        guard isCurrentPlaybackGeneration(generation), canStart() else { return }
        // Preflight may suspend while the source/account is revoked. Re-admit
        // before publishing any synthesizer or playback state.
        let installAdmission: SourceEffectAdmission?
        do { installAdmission = try admitReaderSource(vm) } catch { return }
        defer { installAdmission?.release() }
        let synthesizerBuilder: @MainActor (CustomTTSTokenizer.PDFNarrationTokenizationCursor?) -> PublicationSpeechSynthesizer? = { [weak self, weak vm] cursor in
            guard let self, let vm else { return nil }
            return self.makeReadiumSynthesizer(
                publication: publication,
                settings: self.readiumSettingsForSynthesizer(
                    cursor: cursor,
                    initialSettings: settings
                ),
                vm: vm,
                sessionToken: sessionToken,
                generation: generation,
                granularity: tokenizerGranularity,
                selectionText: startLocator?.text,
                selectionStartPage: startLocator?.locations.page,
                selectionStartUTF16Offset: startLocator?.locations.otherLocations[
                    CustomTTSTokenizer.PDFLocatorMetadata.selectionStartUTF16
                ]?.integer,
                pdfCursor: cursor,
                epubResumePlan: epubResumePlan
            )
        }
        readiumSynthesizerBuilder = synthesizerBuilder

        guard let synthesizer = synthesizerBuilder(nil) else {
            playbackSessionToken = nil
            onFirstUtteranceFailed?()
            return
        }

        playbackSessionToken = sessionToken
        explicitReadAloudForwardIntent = nil
        readiumUtteranceEpoch = 0
        readiumEpochLocator = nil
        readiumEpochText = nil
        readiumObservedLocator = nil
        readiumObservedText = nil
        readiumRestartTarget = nil
        readiumRestartEpoch &+= 1
        ttsState.claimPlaybackSession(sessionToken)
        requiresPlaybackRestart = false
        readiumSynthesizer = synthesizer
        readiumSynthesizerGeneration = generation
        didNotifyFirstUtterance = false
        firstUtteranceGeneration = generation
        hasStartedReadAloudSession = true
        readiumPublication = publication
        readiumPrefetcher = ReadiumTTSPrefetchCoordinator(
            prewarmer: ttsPrewarmer,
            granularity: tokenizerGranularity
        )
        readiumState = .stopped
        currentParagraph = nil
        currentLocator = nil
        lastPlayingLocator = nil
        lastPlayingUtteranceText = nil
        paragraphs = []
        utteranceSeq = 0
        lastLoggedUtteranceText = nil
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        showControls = true

        await registerTTSPreemption(ownerID: sessionToken)
        guard isCurrentPlaybackGeneration(generation), canStart() else {
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return
        }
        await ttsPresence.beginSession(
            bookID: vm.book.id.uuidString,
            title: vm.book.title,
            author: vm.book.author,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
        guard isCurrentPlaybackGeneration(generation), canStart() else {
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return
        }

        // Readium owns publication iteration. The custom tokenizer supplied
        // above keeps EPUB utterances paragraph-scoped and uses sentence
        // utterances for PDF playback.
        guard await activateAudioSessionForReadiumStart() else {
            guard isCurrentPlaybackGeneration(generation), canStart() else {
                await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
                return
            }
            await stopCurrentPlayback()
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            await ttsPresence.endSession()
            showControls = false
            return
        }
        guard isCurrentPlaybackGeneration(generation), canStart() else {
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return
        }
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

    private func admitReaderSource(_ vm: ReaderViewModel) throws -> SourceEffectAdmission? {
        switch (vm.sourceEffects, vm.sourceAccessPermit) {
        case (nil, nil): return nil
        case let (.some(effects), .some(permit)): return try effects.admit(permit)
        default: throw BookSourceAccessError.unknownSource
        }
    }

    private func makeReadiumSynthesizer(
        publication: Publication,
        settings: TTSSettings,
        vm: ReaderViewModel,
        sessionToken: UUID,
        generation: UInt64,
        granularity: CustomTTSTokenizer.Granularity,
        selectionText: Locator.Text?,
        selectionStartPage: Int?,
        selectionStartUTF16Offset: Int?,
        pdfCursor: CustomTTSTokenizer.PDFNarrationTokenizationCursor?,
        epubResumePlan: EPUBNarrationResumePlan?
    ) -> PublicationSpeechSynthesizer? {
        let engineFactory = makeReadiumEngineFactory(
            player: ttsEngine,
            state: ttsState,
            settingsStore: sharedSessionSettingsStore,
            userId: userId,
            sessionToken: sessionToken,
            onUtteranceFinished: { [weak self] in
                await self?.handleUtteranceFinished(generation: generation)
            },
            onUtteranceFailed: { [weak self] in
                await self?.handleUtteranceFailed(generation: generation)
            }
        )
        let isPDF = publication.manifest.conforms(to: .pdf)
        let paragraphMap = isPDF ? PDFNarrationParagraphMap(
            documentURL: vm.documentURL,
            sourceLifetime: vm.sourceLifetime,
            sourceEffects: vm.sourceEffects,
            sourceAccessPermit: vm.sourceAccessPermit
        ) : nil
        let tokenizerFactory = makeReadiumTokenizerFactory(
            granularity: granularity,
            selectionText: selectionText,
            selectionStartPage: selectionStartPage,
            selectionStartUTF16Offset: selectionStartUTF16Offset,
            pdfParagraphMap: paragraphMap,
            pdfCursor: pdfCursor,
            epubResumePlan: epubResumePlan
        )
        return PublicationSpeechSynthesizer(
            publication: publication,
            config: .init(
                defaultLanguage: publication.metadata.language,
                voiceIdentifier: settings.voice
            ),
            engineFactory: engineFactory,
            tokenizerFactory: tokenizerFactory,
            delegate: self
        )
    }

    private func readiumSettingsForSynthesizer(
        cursor: CustomTTSTokenizer.PDFNarrationTokenizationCursor?,
        initialSettings: TTSSettings
    ) -> TTSSettings {
        // The initial synthesizer uses settings loaded at session start.
        // Replacement synthesizers must pick up changes made while it played.
        cursor == nil ? initialSettings : pickerInitial
    }

    private func acceptReadiumSynthesizerRestart() {
        isReadiumPlaybackPaused = false
        ttsState.update(status: .playing)
    }

    #if DEBUG
    var pdfReplacementSettingsForTests: TTSSettings {
        readiumSettingsForSynthesizer(cursor: .init(targetPage: 1), initialSettings: .default)
    }

    var isReadiumPlaybackPausedForTests: Bool { isReadiumPlaybackPaused }
    var playbackStatusForTests: TTSStatus { ttsState.status }

    func setReadiumPlaybackPausedForTests(_ paused: Bool) {
        isReadiumPlaybackPaused = paused
        ttsState.update(status: paused ? .paused : .playing)
    }

    func acceptPDFSynthesizerRestartForTests() {
        acceptReadiumSynthesizerRestart()
    }
    #endif

    func stop(
        preservingPosition: Bool,
        lease: RemoteCommandLease? = nil
    ) async {
        guard lease?.isValid ?? true else { return }
        onPlaybackSessionInvalidated?()
        let stoppingGeneration = playbackGeneration
        let stoppingSessionToken = playbackSessionToken
        let resumeLocator = preservingPosition ? currentLocator : nil
        let ownsSessionBeforeStop = stoppingSessionToken.map {
            ttsState.ownsPlaybackSession($0)
        } ?? (ttsState.playbackSessionToken == nil)
        invalidatePlaybackGeneration()
        if !preservingPosition { acceptsReadAloudPositionUpdates = false }
        isPageEntryPrefetchEligible = true
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        await drainTerminalPlaybackTeardown()
        guard lease?.isValid ?? true,
              playbackGeneration == stoppingGeneration &+ 1,
              ownsSessionBeforeStop else { return }
        if let resumeLocator { await onPersistReadAloudPosition?(resumeLocator) }
        guard lease?.isValid ?? true,
              playbackGeneration == stoppingGeneration &+ 1 else { return }
        if let stoppingSessionToken,
           ttsState.ownsPlaybackSession(stoppingSessionToken) {
            await stopCurrentPlayback(lease: lease)
        } else if ttsState.playbackSessionToken != nil {
            return
        }
        guard lease?.isValid ?? true,
              playbackGeneration == stoppingGeneration &+ 1,
              ttsState.playbackSessionToken == nil else { return }
        if let failureToken = stoppingSessionToken ?? terminalFailureSessionToken {
            ttsState.clearPreservedFailure(ifCurrent: failureToken)
        }
        await ttsPresence.endSession()
        guard playbackGeneration == stoppingGeneration &+ 1 else { return }
        showControls = false
        showPicker = false
        paragraphs = []
        currentParagraph = nil
        currentLocator = nil
    }

    func stop(lease: RemoteCommandLease? = nil) async {
        await stop(preservingPosition: true, lease: lease)
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

    var hasActivePlaybackSession: Bool {
        playbackSessionToken != nil || readiumSynthesizer != nil || bridge != nil
    }

    /// Starts a user-navigation intent and snapshots spoken state for that swipe.
    @discardableResult
    func beginUserNavigationIntent() -> ReadAloudUserNavigationSnapshot {
        navigationIntentGeneration &+= 1
        explicitReadAloudForwardIntent = nil
        return ReadAloudUserNavigationSnapshot(
            generation: navigationIntentGeneration,
            isActivelySpeaking: isActivelySpeaking,
            spokenParagraph: readiumObservedText ?? currentParagraph,
            spokenPage: (readiumObservedLocator ?? currentLocator)?.locations.page,
            followCreditRemaining: followCreditRemaining,
            playbackToken: playbackSessionToken,
            playbackGeneration: playbackGeneration,
            utteranceEpoch: readiumUtteranceEpoch
        )
    }

    /// Captures a local PDF narration session before the reader starts its
    /// deliberate Next-page animation. Shared followers and other sessions do
    /// not create a local restart intent.
    func beginExplicitPageForwardIntent() -> UUID? {
        guard isPDFReadAloudSession,
              let playbackSessionToken,
              readiumSynthesizer != nil,
              ttsState.ownsPlaybackSession(playbackSessionToken) else { return nil }
        navigationIntentGeneration &+= 1
        let id = UUID()
        acceptsReadAloudPositionUpdates = true
        explicitReadAloudForwardIntent = ExplicitReadAloudForwardIntent(
            id: id,
            playbackToken: playbackSessionToken,
            playbackGeneration: playbackGeneration,
            navigationGeneration: navigationIntentGeneration,
            spokenPage: currentLocator?.locations.page,
            utteranceEpoch: readiumUtteranceEpoch
        )
        return id
    }

    /// Called on every reader Next-page exit path. A failed or boundary turn
    /// retires only the matching intent; a successful turn leaves it armed for
    /// the correlated destination callback.
    func completeExplicitForward(id: UUID, didMove: Bool) {
        guard explicitReadAloudForwardIntent?.id == id else { return }
        if !didMove { explicitReadAloudForwardIntent = nil }
    }

    func restartAtExplicitPage(_ locator: Locator, id: UUID) -> ExplicitForwardPlaybackResult {
        guard let intent = explicitReadAloudForwardIntent,
              intent.id == id,
              intent.playbackToken == playbackSessionToken,
              intent.playbackGeneration == playbackGeneration,
              intent.navigationGeneration == navigationIntentGeneration,
              ttsState.ownsPlaybackSession(intent.playbackToken),
              let activeSynthesizer = readiumSynthesizer,
              let destinationPage = locator.locations.page else { return .rejected }

        if currentLocator?.locations.page == destinationPage {
            explicitReadAloudForwardIntent = nil
            return .alreadyReadingDestination
        }
        clearPDFUtteranceSkipQueue()
        let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(
            targetPage: destinationPage
        )
        guard replacePDFSynthesizer(
            old: activeSynthesizer,
            cursor: cursor,
            startLocator: locator,
            targetPage: destinationPage,
            targetParagraphStart: nil,
            targetOrdinal: nil
        ) else { return .rejected }
        explicitReadAloudForwardIntent = nil
        return .restarted
    }

    private var isPDFReadAloudSession: Bool {
        readiumPublication?.manifest.conforms(to: .pdf) == true
            || readerViewModel?.book.formatType == .pdf
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
        guard snapshot.playbackToken == playbackSessionToken,
              snapshot.playbackGeneration == playbackGeneration else {
            return nil
        }
        let effectiveSnapshot: ReadAloudUserNavigationSnapshot
        let liveParagraph = readiumObservedText ?? currentParagraph
        let extractionContainsOriginalParagraph = ReadAloudUserNavigationIntent.containsWholeParagraph(
            snapshot.spokenParagraph, in: destinationParagraphs
        )
        let extractionContainsLiveParagraph = ReadAloudUserNavigationIntent.containsWholeParagraph(
            liveParagraph, in: destinationParagraphs
        )
        if snapshot.utteranceEpoch == readiumUtteranceEpoch
            || (extractionContainsOriginalParagraph && !extractionContainsLiveParagraph) {
            // An old whole paragraph can also be a fragment of the next
            // utterance. Continuing that extraction spends only its old credit.
            effectiveSnapshot = snapshot
        } else {
            // Extraction may take long enough for the same session to advance.
            // Resolve against its live passage while retaining the original
            // destination extraction and swipe generation.
            effectiveSnapshot = ReadAloudUserNavigationSnapshot(
                generation: snapshot.generation,
                isActivelySpeaking: isActivelySpeaking,
                spokenParagraph: readiumObservedText ?? currentParagraph,
                spokenPage: (readiumObservedLocator ?? currentLocator)?.locations.page,
                followCreditRemaining: readiumObservedText != lastLoggedUtteranceText
                    ? 1
                    : followCreditRemaining,
                playbackToken: playbackSessionToken,
                playbackGeneration: playbackGeneration,
                utteranceEpoch: readiumUtteranceEpoch
            )
        }
        let intent = ReadAloudUserNavigationIntent.resolve(
            isActivelySpeaking: effectiveSnapshot.isActivelySpeaking,
            spokenParagraph: effectiveSnapshot.spokenParagraph,
            destinationParagraphs: destinationParagraphs,
            spokenPage: effectiveSnapshot.spokenPage,
            destinationPage: destinationPage,
            followCreditRemaining: effectiveSnapshot.followCreditRemaining
        )
        switch intent {
        case .continuePlaying(consumesFollowCredit: true):
            // Only burn credit belonging to the snapshotted utterance. If the
            // utterance advanced during extract, live credit was refilled for
            // the new text — leave it alone.
            if lastLoggedUtteranceText == effectiveSnapshot.spokenParagraph {
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
        readiumUtteranceEpoch &+= 1
        followCreditRemaining = 1
    }

    /// Test setup for the stop-path resume handoff without constructing a
    /// Readium publication synthesizer.
    func setReadAloudPositionForTests(_ locator: Locator) {
        currentLocator = locator
    }
    #endif

    /// Fences late Readium state callbacks after a deliberate manual
    /// navigation has selected a new destination.
    func invalidateReadAloudPositionUpdates() {
        acceptsReadAloudPositionUpdates = false
    }

    func allowReadAloudPositionUpdates() {
        acceptsReadAloudPositionUpdates = true
    }

    func togglePlayback(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        if readiumSynthesizer != nil {
            if isReadiumPlaybackPaused {
                await resumeReadiumPlayback(lease: lease)
            } else if case .playing = readiumState {
                await pauseReadiumPlayback(lease: lease)
            }
        } else if let bridge {
            if ttsState.status == .playing {
                isPageEntryPrefetchEligible = true
                await bridge.pause(lease: lease)
            } else {
                isPageEntryPrefetchEligible = false
                await bridge.resume(lease: lease)
            }
        }
        guard lease?.isValid ?? true else { return }
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

    private func registerTTSPreemption(ownerID: UUID) async {
        await coordinator.registerPreemption(for: .tts, ownerID: ownerID) { [weak self] in
            await self?.pauseForVoiceHandoff()
        }
        await coordinator.registerRecovery(for: .tts, ownerID: ownerID) { [weak self] in
            await self?.resumeAfterVoiceIfNeeded()
        }
        await coordinator.registerSuspension(for: .tts, ownerID: ownerID) { [weak self] in
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

    private func pauseReadiumPlayback(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        guard !isReadiumPlaybackPaused,
              case .playing = readiumState
        else { return }

        await ttsEngine.pause(lease: lease ?? TTSAlwaysValidLease())
        guard lease?.isValid ?? true else { return }
        isReadiumPlaybackPaused = true
        isPageEntryPrefetchEligible = true
        ttsState.update(status: .paused)
    }

    private func resumeReadiumPlayback(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        guard isReadiumPlaybackPaused else { return }

        if let sharedFollowerResumeAnchor, let readiumSynthesizer {
            self.sharedFollowerResumeAnchor = nil
            currentLocator = sharedFollowerResumeAnchor
            isReadiumPlaybackPaused = false
            isPageEntryPrefetchEligible = false
            ttsState.update(status: .playing)
            readiumSynthesizer.start(from: sharedFollowerResumeAnchor)
            return
        }

        await ttsEngine.resume(lease: lease ?? TTSAlwaysValidLease())
        guard lease?.isValid ?? true else { return }
        isReadiumPlaybackPaused = false
        isPageEntryPrefetchEligible = false
        ttsState.update(status: .playing)
    }

    /// Claims the shared playback session before Readium starts delivering
    /// speech. Unlike the legacy bridge, Readium bypasses `ReaderTTSBridge`,
    /// so it must activate `.playback` / `.spokenAudio` itself.
    func activateAudioSessionForReadiumStart() async -> Bool {
        await coordinator.requestActiveMode(.tts)
    }

    private func enqueuePDFUtteranceSkip(_ delta: Int, lease: RemoteCommandLease?) {
        guard delta == -1 || delta == 1,
              lease?.isValid ?? true,
              let token = playbackSessionToken,
              let synthesizer = readiumSynthesizer else { return }
        let initialCursor: PDFNarrationCursor?
        if let locator = currentLocator,
           let page = locator.locations.page,
           let ordinal = locator.locations.otherLocations[
               CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal
           ]?.integer {
            initialCursor = PDFNarrationCursor(page: page, ordinal: ordinal)
        } else { initialCursor = nil }
        pdfNarrationSequencer.enqueue(
            PDFNarrationSkipRequest(delta: delta, playbackToken: token, playbackGeneration: playbackGeneration, lease: lease),
            initialCursor: initialCursor, synthesizerID: ObjectIdentifier(synthesizer)
        )
    }

    private func applyPDFUtteranceTarget(_ target: PDFNarrationTarget, expectedSynthesizerID: ObjectIdentifier) -> ObjectIdentifier? {
        guard let synthesizer = readiumSynthesizer,
              ObjectIdentifier(synthesizer) == expectedSynthesizerID else { return nil }
        clearReadAloudRestartFenceForSkip()
        let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(targetPage: target.page, utteranceOrdinal: target.ordinal)
        guard replacePDFSynthesizer(
            old: synthesizer, cursor: cursor, startLocator: target.locator,
            targetPage: target.page, targetParagraphStart: target.paragraphStart, targetOrdinal: target.ordinal
        ), let replacement = readiumSynthesizer else { return nil }
        return ObjectIdentifier(replacement)
    }

    private func resolvePDFUtteranceTarget(
        from cursor: PDFNarrationCursor,
        delta: Int
    ) async -> PDFNarrationTarget? {
        guard let publication = readiumPublication,
              let base = currentLocator,
              let readerViewModel else { return nil }
        let input = PDFNarrationLookupInput(
            publication: publication,
            documentURL: readerViewModel.documentURL,
            baseLocator: base,
            sourceLifetime: readerViewModel.sourceLifetime,
            sourceEffects: readerViewModel.sourceEffects,
            sourceAccessPermit: readerViewModel.sourceAccessPermit
        )
        return await PDFNarrationTargetResolver.resolve(input: input, cursor: cursor, delta: delta)
    }

    private func clearPDFUtteranceSkipQueue() {
        pdfNarrationSequencer.cancel()
    }

    private func clearReadAloudRestartFenceForSkip() {
        readiumRestartEpoch &+= 1
        readiumRestartTarget = nil
    }

    private func replacePDFSynthesizer(
        old: PublicationSpeechSynthesizer,
        cursor: CustomTTSTokenizer.PDFNarrationTokenizationCursor,
        startLocator: Locator,
        targetPage: Int,
        targetParagraphStart: Int?,
        targetOrdinal: Int?
    ) -> Bool {
        guard let builder = readiumSynthesizerBuilder,
              readiumSynthesizer === old,
              let newSynthesizer = builder(cursor) else { return false }
        readiumRestartEpoch &+= 1
        readiumRestartTarget = (targetPage, targetParagraphStart, targetOrdinal)
        readiumSynthesizer = newSynthesizer
        readiumSynthesizerGeneration = playbackGeneration
        acceptReadiumSynthesizerRestart()
        old.stop()
        newSynthesizer.start(from: startLocator)
        return true
    }

    func previous(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        if let readiumSynthesizer {
            if isPDFReadAloudSession {
                enqueuePDFUtteranceSkip(-1, lease: lease)
            } else {
                readiumSynthesizer.previous()
            }
        } else {
            await bridge?.previous(lease: lease)
        }
    }

    func next(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        if let readiumSynthesizer {
            if isPDFReadAloudSession {
                enqueuePDFUtteranceSkip(1, lease: lease)
            } else {
                readiumSynthesizer.next()
            }
        } else {
            await bridge?.next(lease: lease)
        }
    }

    func repeatCurrent() async {
        if let readiumSynthesizer, let currentLocator {
            guard isPDFReadAloudSession else {
                guard await coordinator.requestActiveMode(.tts) else { return }
                readiumSynthesizer.start(from: currentLocator)
                return
            }
            guard let token = playbackSessionToken,
                  let page = currentLocator.locations.page,
                  let paragraphStart = currentLocator.locations.otherLocations[
                    CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16
                  ]?.integer else {
                Log.event("tts.readaloud.pdf.repeat_unavailable", level: .warning)
                return
            }
            let targetLocator = currentLocator
            let navigationGeneration = navigationIntentGeneration
            let generation = playbackGeneration
            guard await coordinator.requestActiveMode(.tts),
                  self.readiumSynthesizer === readiumSynthesizer,
                  self.playbackSessionToken == token,
                  navigationIntentGeneration == navigationGeneration,
                  isCurrentPlaybackGeneration(generation),
                  ttsState.ownsPlaybackSession(token) else { return }

            clearPDFUtteranceSkipQueue()
            navigationIntentGeneration &+= 1
            explicitReadAloudForwardIntent = nil
            acceptsReadAloudPositionUpdates = true
            let cursor = CustomTTSTokenizer.PDFNarrationTokenizationCursor(
                targetPage: page,
                paragraphStartUTF16: paragraphStart
            )
            _ = replacePDFSynthesizer(
                old: readiumSynthesizer,
                cursor: cursor,
                startLocator: targetLocator,
                targetPage: page,
                targetParagraphStart: paragraphStart,
                targetOrdinal: nil
            )
        } else {
            await bridge?.repeatCurrent()
        }
    }

    func applySettings(_ settings: TTSSettings, lease: RemoteCommandLease? = nil) async {
        let mutationLease: any TTSMutationLease = lease ?? TTSAlwaysValidLease()
        guard mutationLease.isValid else { return }
        await ttsSettingsStore.save(settings, userId: userId, lease: mutationLease)
        guard mutationLease.isValid else { return }
        pickerInitial = settings
        guard mutationLease.isValid else { return }
        readiumSynthesizer?.config.voiceIdentifier = settings.voice
        await readiumPrefetcher?.stop()
        guard mutationLease.isValid else { return }
        await ttsPresence.updatePlaybackSettings(
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
        guard mutationLease.isValid else { return }
    }

    /// Sets the controller's speed for this reader instance only. A running
    /// stream keeps its original rate until the caller restarts at the current
    /// authoritative locator; the return value tells it when that is needed.
    func applySharedSessionRate(
        _ rate: Double,
        fence requestedFence: SharedRateMutationFence? = nil
    ) async -> Bool {
        guard rate.isFinite, TTSSettings.speedRange.contains(rate) else { return false }
        let fence = requestedFence ?? nextSharedRateFence()
        guard advanceSharedRateFence(to: fence, allowingNewScope: true) else { return false }
        let changed = abs(pickerInitial.speed - rate) >= 0.0001
        _ = await sharedSessionSettingsStore.setSharedRate(rate, fence: fence)
        guard sharedRateMutationFence == fence else { return false }
        let saved = await ttsSettingsStore.load(userId: userId)
        guard sharedRateMutationFence == fence else { return false }
        pickerInitial = TTSSettings(voice: saved.voice, model: saved.model, speed: rate)
        guard sharedRateMutationFence == fence else { return false }
        await ttsPresence.updatePlaybackSettings(
            voice: saved.voice,
            model: saved.model,
            speed: rate
        )
        return sharedRateMutationFence == fence && changed
    }

    func updateSharedFollowerResumeAnchor(_ locator: Locator) async {
        switch localPlaybackPhase {
        case .playing:
            return
        case .noSession:
            sharedFollowerResumeAnchor = locator
            await onPersistReadAloudPosition?(locator)
            return
        case .paused:
            break
        }
        sharedFollowerResumeAnchor = locator
        currentLocator = locator
        await onPersistReadAloudPosition?(locator)
    }

    @discardableResult
    func applySharedFollowerAudioReconfiguration(
        readerViewModel: ReaderViewModel,
        rate: Double,
        cursor: Locator?,
        phase: SharedReadingDesiredPlayback,
        revision: SharedReadingEffectRevision,
        rateFence requestedRateFence: SharedRateMutationFence? = nil,
        restartAt requestedRestartAt: Locator? = nil
    ) async -> Bool {
        let rateFence = requestedRateFence ?? SharedRateMutationFence(
            scopeID: sharedRateMutationFence?.scopeID ?? UUID(),
            revision: max(revision.generation, (sharedRateMutationFence?.revision ?? 0) + 1)
        )
        guard rateFence.revision > (sharedFollowerAudioFence?.revision ?? 0) else { return false }
        sharedFollowerAudioFence = rateFence
        sharedFollowerAudioRevision = revision

        let rateChanged = await applySharedSessionRate(rate, fence: rateFence)
        guard sharedFollowerAudioFence == rateFence,
              sharedFollowerAudioRevision == revision,
              sharedRateMutationFence == rateFence else { return false }

        switch phase {
        case .paused:
            if case .playing = localPlaybackPhase { await pause() }
            guard sharedFollowerAudioFence == rateFence,
                  sharedFollowerAudioRevision == revision,
                  sharedRateMutationFence == rateFence else { return false }
            if let target = cursor ?? (rateChanged ? currentLocator : nil) {
                await updateSharedFollowerResumeAnchor(target)
                guard sharedFollowerAudioFence == rateFence,
                      sharedFollowerAudioRevision == revision,
                      sharedRateMutationFence == rateFence else { return false }
            }
        case .playing:
            let target = cursor ?? currentLocator
            if case .paused = localPlaybackPhase, let target,
               sharedFollowerResumeAnchor == nil || narrationCursorNeedsRealignment(to: target) {
                await updateSharedFollowerResumeAnchor(target)
                guard sharedFollowerAudioFence == rateFence,
                      sharedFollowerAudioRevision == revision,
                      sharedRateMutationFence == rateFence else { return false }
            }
            let restartAt = requestedRestartAt
                ?? ((rateChanged || (target.map(narrationCursorNeedsRealignment(to:)) ?? false)) ? target : nil)
            if let restartAt, let readiumSynthesizer, hasActivePlaybackSession {
                sharedFollowerResumeAnchor = nil
                currentLocator = restartAt
                readiumSynthesizer.start(from: restartAt)
            } else if case .paused = localPlaybackPhase {
                await resume()
                guard sharedFollowerAudioFence == rateFence,
                      sharedFollowerAudioRevision == revision,
                      sharedRateMutationFence == rateFence else { return false }
            } else if case .noSession = localPlaybackPhase {
                // Shared followers can create this controller before any local
                // playback has supplied its reader model. Start from the model
                // owned by the destination that is applying this progress.
                await startReader(vm: readerViewModel, startLocator: target)
                guard sharedFollowerAudioRevision == revision,
                      sharedRateMutationFence == rateFence else { return false }
            }
        }
        return sharedFollowerAudioFence == rateFence
            && sharedFollowerAudioRevision == revision
            && sharedRateMutationFence == rateFence
    }

    private func narrationCursorNeedsRealignment(to target: Locator) -> Bool {
        guard let currentLocator else { return true }
        return target.href != currentLocator.href
            || target.locations.page != currentLocator.locations.page
            || abs((target.locations.progression ?? 0) - (currentLocator.locations.progression ?? 0)) > 0.08
    }

    /// Restores local settings when the follower leaves the room. This never
    /// writes the room's speed to the persisted settings store.
    func clearSharedSessionRate(fence requestedFence: SharedRateMutationFence? = nil) async {
        let fence = requestedFence ?? nextSharedRateFence()
        guard advanceSharedRateFence(to: fence, allowingNewScope: false) else { return }
        guard await sharedSessionSettingsStore.clearSharedRate(fence: fence),
              sharedRateMutationFence == fence else { return }
        let settings = await ttsSettingsStore.load(userId: userId)
        guard sharedRateMutationFence == fence else { return }
        pickerInitial = settings
        guard sharedRateMutationFence == fence else { return }
        await ttsPresence.updatePlaybackSettings(
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
    }

    private func nextSharedRateFence() -> SharedRateMutationFence {
        SharedRateMutationFence(
            scopeID: sharedRateMutationFence?.scopeID ?? UUID(),
            revision: (sharedRateMutationFence?.revision ?? 0) + 1
        )
    }

    private func advanceSharedRateFence(
        to fence: SharedRateMutationFence,
        allowingNewScope: Bool
    ) -> Bool {
        guard let current = sharedRateMutationFence else {
            sharedRateMutationFence = fence
            return true
        }
        if current.scopeID != fence.scopeID {
            guard allowingNewScope, fence.revision > current.revision else { return false }
            sharedRateMutationFence = fence
            return true
        }
        guard fence.revision > current.revision else { return false }
        sharedRateMutationFence = fence
        return true
    }

    /// Applies a speed selected by a system media surface. Keep this guard in
    /// the reader as well as in the command surface so invalid direct callers
    /// cannot persist unsupported values.
    func applyPlaybackRate(_ rate: Double, lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        guard TTSSettings.speedPresets.contains(where: { abs($0 - rate) < 0.0001 }) else { return }
        guard abs(pickerInitial.speed - rate) >= 0.0001 else { return }
        await applySettings(
            TTSSettings(voice: pickerInitial.voice, model: pickerInitial.model, speed: rate),
            lease: lease
        )
        guard lease?.isValid ?? true else { return }
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
        await drainTerminalPlaybackTeardown()
        guard isCurrentPlaybackGeneration(generation) else { return }
        if let terminalFailureSessionToken {
            ttsState.clearPreservedFailure(ifCurrent: terminalFailureSessionToken)
        }
        acceptsReadAloudPositionUpdates = true

        isPageEntryPrefetchEligible = false
        await stopCurrentPlayback()
        guard isCurrentPlaybackGeneration(generation) else { return }
        let sessionToken = UUID()
        playbackSessionToken = sessionToken

        let wrappedOnParagraphsExhausted: () async -> [String] = { [weak self] in
            guard let self,
                  self.playbackSessionToken == sessionToken,
                  self.ttsState.ownsPlaybackSession(sessionToken)
            else { return [] }
            let nextParagraphs = await onParagraphsExhausted()
            guard self.playbackSessionToken == sessionToken,
                  self.ttsState.ownsPlaybackSession(sessionToken)
            else { return [] }
            if nextParagraphs.isEmpty {
                self.isPageEntryPrefetchEligible = true
                self.nowPlayingController?.detach()
            } else {
                self.isPageEntryPrefetchEligible = false
            }
            return nextParagraphs
        }
        let wrappedOnParagraphsBeforeStart: () async -> [String] = { [weak self] in
            guard let self,
                  self.playbackSessionToken == sessionToken,
                  self.ttsState.ownsPlaybackSession(sessionToken)
            else { return [] }
            let previousParagraphs = await onParagraphsBeforeStart()
            guard self.playbackSessionToken == sessionToken,
                  self.ttsState.ownsPlaybackSession(sessionToken)
            else { return [] }
            return previousParagraphs
        }

        let tracker = TTSPassageTracker()
        let newBridge = ReaderTTSBridge(
            engine: ttsEngine,
            state: ttsState,
            tracker: tracker,
            prewarmer: ttsPrewarmer,
            settingsStore: sharedSessionSettingsStore,
            userId: userId,
            coordinator: coordinator,
            onPassageChange: onPassageChange,
            onParagraphsExhausted: wrappedOnParagraphsExhausted,
            onParagraphsBeforeStart: wrappedOnParagraphsBeforeStart,
            sessionToken: sessionToken
        )
        bridge = newBridge
        ttsState.claimPlaybackSession(sessionToken)
        requiresPlaybackRestart = false
        hasStartedReadAloudSession = true
        self.paragraphs = paragraphs
        currentParagraph = nil
        pickerInitial = await sharedSessionSettingsStore.load(userId: userId)
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else { return }
        await ttsPresence.beginSession(
            bookID: bookID,
            title: metadata.title,
            author: metadata.author,
            voice: pickerInitial.voice,
            model: pickerInitial.model,
            speed: pickerInitial.speed
        )
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else {
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return
        }
        showControls = true
        await registerTTSPreemption(ownerID: sessionToken)
        guard isCurrentPlaybackGeneration(generation), bridge === newBridge else {
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return
        }
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
        let bridgeStarted = await newBridge.start(paragraphs: paragraphs, startIndex: startIndex)
        guard bridgeStarted else {
            guard isCurrentPlaybackGeneration(generation), bridge === newBridge else {
                await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
                return
            }
            await stopCurrentPlayback()
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            bridge = nil
            await ttsPresence.endSession()
            showControls = false
            return
        }
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

        let settings = await sharedSessionSettingsStore.load(userId: userId)
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

    private func handleUtteranceFinished(generation: UInt64) {
        guard firstUtteranceGeneration == generation,
              !didNotifyFirstUtterance else { return }
        didNotifyFirstUtterance = true
        onFirstUtteranceFinished?()
    }

    private func handleUtteranceFailed(generation: UInt64) {
        guard firstUtteranceGeneration == generation,
              !didNotifyFirstUtterance else { return }
        didNotifyFirstUtterance = true
        onFirstUtteranceFailed?()
    }

    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }

    /// Both failure callbacks synchronously reserve the same cleanup handle.
    /// Starts and explicit stops drain it before changing playback ownership.
    private func enqueueTerminalPlaybackTeardown(
        sessionToken: UUID,
        playbackGeneration: UInt64,
        preservingFailure: Bool
    ) -> Task<Void, Never> {
        requiresPlaybackRestart = true
        terminalFailureSessionToken = sessionToken
        if let identity = terminalPlaybackTeardownIdentity,
           identity.session == sessionToken,
           identity.generation == playbackGeneration,
           let task = terminalPlaybackTeardownTask {
            return task
        }
        let id = UUID()
        let previous = terminalPlaybackTeardownTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.playbackSessionToken == sessionToken else { return }
            await self.teardownPlaybackSession(preservingFailure: preservingFailure)
            if self.terminalPlaybackTeardownIdentity?.id == id {
                self.terminalPlaybackTeardownTask = nil
                self.terminalPlaybackTeardownIdentity = nil
            }
        }
        terminalPlaybackTeardownIdentity = (sessionToken, playbackGeneration, id)
        terminalPlaybackTeardownTask = task
        return task
    }

    #if DEBUG
    var playbackGenerationForRecoveryTests: UInt64 { playbackGeneration }

    @discardableResult
    func enqueuePlaybackFailureForTests() -> Task<Void, Never>? {
        guard let sessionToken = playbackSessionToken else { return nil }
        if ttsState.typedFailure == nil { ttsState.recordUserFacingFailure(.audioPlayback) }
        return enqueueTerminalPlaybackTeardown(
            sessionToken: sessionToken,
            playbackGeneration: playbackGeneration,
            preservingFailure: true
        )
    }
    #endif

    func drainTerminalPlaybackTeardown() async {
        while let task = terminalPlaybackTeardownTask {
            let id = terminalPlaybackTeardownIdentity?.id
            await task.value
            if terminalPlaybackTeardownIdentity?.id == id {
                terminalPlaybackTeardownTask = nil
                terminalPlaybackTeardownIdentity = nil
            }
        }
    }

    private func teardownPlaybackSession(
        preservingFailure: Bool = false,
        lease: RemoteCommandLease? = nil
    ) async {
        guard lease?.isValid ?? true else { return }
        // Capture the old resources before keyboard/prefetch cleanup suspends.
        let ownedSessionToken = playbackSessionToken
        let capturedBridge = bridge
        let capturedSynthesizer = readiumSynthesizer
        let capturedPrefetcher = readiumPrefetcher
        let capturedRequestTokens = ttsState.activeTokenSnapshot
        let generation = playbackGeneration
        func stillCurrent() -> Bool {
            playbackSessionToken == ownedSessionToken && playbackGeneration == generation
        }
        clearPDFUtteranceSkipQueue()
        explicitReadAloudForwardIntent = nil
        readiumRestartTarget = nil
        readiumRestartEpoch &+= 1
        playbackTeardownDepth += 1
        defer { playbackTeardownDepth -= 1 }
        let inFlightKeyboardNavigation = keyboardParagraphNavigationTask
        keyboardParagraphNavigationGeneration &+= 1
        keyboardParagraphNavigationTask?.cancel()
        keyboardParagraphNavigationTask = nil
        await inFlightKeyboardNavigation?.value
        guard lease?.isValid ?? true,
              playbackSessionToken == ownedSessionToken else { return }
        let ownsSharedSession = ownedSessionToken.map { ttsState.ownsPlaybackSession($0) } ?? false
        if ownsSharedSession { nowPlayingController?.detach() }
        Log.event("tts.nav.stop", data: [
            "hadSynthesizer": capturedSynthesizer != nil ? "1" : "0",
            "lastSeq": String(max(0, utteranceSeq - 1)),
            "lastPrefix": lastLoggedUtteranceText.map { String($0.prefix(60)) } ?? "",
        ])
        await capturedPrefetcher?.stop()
        guard lease?.isValid ?? true,
              playbackSessionToken == ownedSessionToken else { return }
        if let capturedBridge { await capturedBridge.stop(lease: lease) }
        guard lease?.isValid ?? true,
              playbackSessionToken == ownedSessionToken else { return }
        // A stop can invalidate this generation while it drains this task;
        // its replacement cannot start until the same handle has completed.
        guard stillCurrent() || terminalPlaybackTeardownIdentity?.session == ownedSessionToken else { return }
        if bridge === capturedBridge { bridge = nil }
        if readiumPrefetcher === capturedPrefetcher { readiumPrefetcher = nil }
        if readiumSynthesizer === capturedSynthesizer { readiumSynthesizer = nil }
        readiumPublication = nil
        readiumSynthesizerBuilder = nil
        isReadiumPlaybackPaused = false
        lastPlayingLocator = nil
        lastPlayingUtteranceText = nil
        if let ownedSessionToken, ttsState.ownsPlaybackSession(ownedSessionToken) {
            capturedSynthesizer?.stop()
            // Readium cancellation starts engine stop asynchronously. Drain
            // the tokened player too so this handle includes audio teardown.
            if capturedSynthesizer != nil,
               let capturedRequestTokens,
               capturedRequestTokens.sessionToken == ownedSessionToken {
                await ttsEngine.stop(ifCurrent: capturedRequestTokens, lease: lease ?? TTSAlwaysValidLease())
                guard playbackSessionToken == ownedSessionToken else { return }
            }
        }
        readiumState = .stopped
        playbackSessionToken = nil
        readiumEpochLocator = nil
        readiumEpochText = nil
        readiumObservedLocator = nil
        readiumObservedText = nil
        firstUtteranceGeneration = nil
        followCreditRemaining = 0
        #if DEBUG
        testSpeakingOverride = false
        #endif
        guard let ownedSessionToken,
              ttsState.endSession(preservingFailure: preservingFailure, ifCurrent: ownedSessionToken)
        else { return }
        await coordinator.releaseActiveMode(.tts)
        await coordinator.unregisterHandlers(for: .tts, ownerID: ownedSessionToken)
    }

    private func stopCurrentPlayback(lease: RemoteCommandLease? = nil) async {
        await teardownPlaybackSession(lease: lease)
    }

    private func handleTypedAllowanceFailure(
        _ failure: WorkerAllowanceError,
        tokens: TTSPlaybackTokenSnapshot,
        playbackGeneration: UInt64,
        observerGeneration: UInt64,
        teardownTask: Task<Void, Never>
    ) async {
        await teardownTask.value
        guard isValidTypedFailure(
            tokens: tokens,
            playbackGeneration: playbackGeneration,
            observerGeneration: observerGeneration,
            allowClearedState: true
        ) else { return }
        onAllowanceFailure?(failure, tokens.sessionToken)
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
            let teardownTask = self.enqueueTerminalPlaybackTeardown(
                sessionToken: tokens.sessionToken,
                playbackGeneration: playbackGeneration,
                preservingFailure: true
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleTypedAllowanceFailure(
                    failure,
                    tokens: tokens,
                    playbackGeneration: playbackGeneration,
                    observerGeneration: observerGeneration,
                    teardownTask: teardownTask
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
        guard isCurrentPlaybackGeneration(generation),
              let sessionToken = playbackSessionToken,
              ttsState.ownsPlaybackSession(sessionToken)
        else { return }
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
                  let sessionToken = self.playbackSessionToken,
                  self.ttsState.ownsPlaybackSession(sessionToken),
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
        guard let sessionToken = playbackSessionToken,
              ttsState.ownsPlaybackSession(sessionToken)
        else { return }

        if let restartTarget = readiumRestartTarget {
            let candidate: PublicationSpeechSynthesizer.Utterance?
            switch state {
            case let .playing(utterance, _), let .paused(utterance):
                candidate = utterance
            case .stopped:
                candidate = nil
            }
            if let candidate {
                let locations = candidate.locator.locations
                let matches = locations.page == restartTarget.page
                    && (restartTarget.paragraphStart == nil
                        || locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.paragraphStartUTF16]?.integer == restartTarget.paragraphStart)
                    && (restartTarget.utteranceOrdinal == nil
                        || locations.otherLocations[CustomTTSTokenizer.PDFLocatorMetadata.utteranceOrdinal]?.integer == restartTarget.utteranceOrdinal)
                guard matches else { return }
                readiumRestartTarget = nil
            }
        }

        switch state {
        case let .playing(utterance, range):
            readiumObservedLocator = range ?? utterance.locator
            readiumObservedText = utterance.text
            if readiumEpochText != utterance.text || readiumEpochLocator != utterance.locator {
                readiumUtteranceEpoch &+= 1
                readiumEpochText = utterance.text
                readiumEpochLocator = utterance.locator
            }
        case let .paused(utterance):
            readiumObservedLocator = utterance.locator
            readiumObservedText = utterance.text
        case .stopped:
            break
        }
        readiumState = state
        let isStopped: Bool
        if case .stopped = state { isStopped = true } else { isStopped = false }
        guard acceptsReadAloudPositionUpdates || isStopped else { return }
        switch state {
        case .stopped:
            clearPDFUtteranceSkipQueue()
            explicitReadAloudForwardIntent = nil
            readiumRestartTarget = nil
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
            let locator: Locator
            if let lastPlayingLocator,
               lastPlayingUtteranceText == utterance.text,
               lastPlayingLocator.href.string == utterance.locator.href.string
            {
                locator = lastPlayingLocator
            } else {
                locator = utterance.locator
            }
            currentLocator = locator
            currentParagraph = utterance.text
            onReadAloudPositionChange?(locator)
            ttsState.update(status: .paused)
        case let .playing(utterance, range):
            isPageEntryPrefetchEligible = false
            currentLocator = range ?? utterance.locator
            currentParagraph = utterance.text
            lastPlayingLocator = currentLocator
            lastPlayingUtteranceText = utterance.text
            onReadAloudPositionChange?(currentLocator ?? utterance.locator)
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
        guard let sessionToken = playbackSessionToken,
              ttsState.ownsPlaybackSession(sessionToken)
        else { return }
        nowPlayingController?.detach()
        readiumState = .stopped
        if ttsState.typedFailure == nil {
            let underlying: Swift.Error
            switch error {
            case .engine(.other(let cause)): underlying = cause
            case .engine(let cause): underlying = cause
            }
            if let userFacingError = TTSUserFacingError.classify(underlying) {
                ttsState.recordUserFacingFailure(userFacingError)
            }
        }
        let preservingFailure = ttsState.typedFailure != nil || ttsState.userFacingFailure != nil
        _ = enqueueTerminalPlaybackTeardown(
            sessionToken: sessionToken,
            playbackGeneration: generation,
            preservingFailure: preservingFailure
        )
    }
}

extension ReadAloudController: TTSPlaybackControlling {
    @MainActor
    func stop() async {
        await stop(lease: nil)
    }

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

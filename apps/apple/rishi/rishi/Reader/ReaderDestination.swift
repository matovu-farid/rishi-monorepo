import SwiftUI
import Observation
import ReadiumShared

struct ReaderDestinationDependencies {
    let readerDefaults: AppReaderDefaults
    let readerSettingsStore: any ReaderSettingsStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let bookSearch: any BookSearch
    let indexingHook: any BookIndexingHook
    let syncEngine: SyncEngine
    let conversationLookup: ConversationLookup
    let messageStore: any MessageStore
    let chatService: any ChatService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let voicePresenter: VoiceSessionPresenter
    let ttsCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: any TTSPlaying
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPresenceController: TTSPresenceController
    let ttsPrewarmer: TTSPrewarmer
    let playbackOwner: ReadAloudPlaybackOwner

    @MainActor
    static func make(services: BootstrappedServices) -> Self {
        Self(
            readerDefaults: services.settings.readerDefaults,
            readerSettingsStore: services.library.readerSettingsStore,
            highlightStore: services.library.highlightStore,
            bookmarkStore: services.library.bookmarkStore,
            bookFileStorage: services.library.bookFileStorage,
            bookSearch: services.library.bookSearch,
            indexingHook: services.library.indexingHook,
            syncEngine: services.sync.engine,
            conversationLookup: services.chat.conversationLookup,
            messageStore: services.chat.messageStore,
            chatService: services.chat.service,
            entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
            entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
            voicePresenter: services.voice.presenter,
            ttsCoordinator: services.audio.coordinator,
            ttsState: services.audio.ttsState,
            ttsEngine: services.audio.ttsEngine,
            ttsSettingsStore: services.audio.ttsSettingsStore,
            nowPlayingController: services.audio.nowPlayingController,
            ttsPresenceController: services.audio.ttsPresenceController,
            ttsPrewarmer: services.audio.ttsPrewarmer,
            playbackOwner: services.audio.playbackOwner
        )
    }
}

@MainActor
@Observable
final class ReaderPaywallRequestHandoff {
    private var pendingRequest: String?

    func queue(_ request: String) {
        pendingRequest = request
    }

    func takeAfterPromptDismissal() -> String? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}












struct ReaderDestination: View {
    let dependencies: ReaderDestinationDependencies
    let userId: UserID
    let onRequestPaywall: (String) -> Void
    let startReaderTour: Bool
    let pdfViewMode: Binding<PDFViewModeSetting>?
    let readerWindowCloseHandle: ReaderWindowCloseHandle?
    let sharedReadingCoordinator: SharedReadingSessionCoordinator?
    let sharedReadingJoin: SharedReadingJoin?
    let sharedReadingPeerMesh: SharedReadingPeerMesh?

    @State private var readAloudStartTask: Task<Void, Never>?
    @State private var readAloudStartRequest = UUID()
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    private let readAloudHost = UUID()
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?
    @State private var pendingNarrationUpgradeSessionToken: UUID?
    @State private var paywallRequestHandoff = ReaderPaywallRequestHandoff()
    @State private var didScheduleReaderIndexBackfill = false
    @State private var sharedPositionJSONString: String?
    @State private var sharedSequence: Int64 = 0
    @State private var sharedMicrophonePolicy = SharedReadingMicrophonePolicyState()
    @State private var sharedTTSIsPlaying = false

    @State private var voiceEntry: ReaderVoiceEntry
    @State private var readerTour: ReaderOnboardingTourCoordinator?
    @State private var showVoiceTextChat = false
    @State private var voiceTextVM: ChatPanelViewModel?
    /// Keep the EPUB viewport stable before playback starts. This is the
    /// compact player's reserved maximum, including its card and controls.
    private static let playerReservationHeight: CGFloat = 96

    init(
        vm: ReaderViewModel,
        dependencies: ReaderDestinationDependencies,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void,
        startReaderTour: Bool = false,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil,
        readerWindowCloseHandle: ReaderWindowCloseHandle? = nil,
        sharedReadingCoordinator: SharedReadingSessionCoordinator? = nil,
        sharedReadingJoin: SharedReadingJoin? = nil,
        sharedReadingPeerMesh: SharedReadingPeerMesh? = nil
    ) {
        let peeked = dependencies.readerSettingsStore.peekPersistedTheme(for: vm.book.id)
        let initial = peeked ?? dependencies.readerDefaults.theme
        vm.theme = initial

        self._vm = State(initialValue: vm)
        self.dependencies = dependencies
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self.startReaderTour = startReaderTour
        self.pdfViewMode = pdfViewMode
        self.readerWindowCloseHandle = readerWindowCloseHandle
        self.sharedReadingCoordinator = sharedReadingCoordinator
        self.sharedReadingJoin = sharedReadingJoin
        self.sharedReadingPeerMesh = sharedReadingPeerMesh
        let tour = startReaderTour ? ReaderOnboardingTourCoordinator() : nil
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: dependencies.voicePresenter,
            voiceLanguageProvider: { dependencies.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: dependencies.entitlementSnapshotStore,
            onRequestPaywall: onRequestPaywall,
            onVoiceStarted: { tour?.voiceChatStarted() }
        ))
        self._readerTour = State(initialValue: tour)
    }

    var body: some View {
        ReaderScreen(
            viewModel: vm,
            appDefaultTheme: dependencies.readerDefaults.theme,
            readerSettingsStore: dependencies.readerSettingsStore,
            highlightStore: dependencies.highlightStore,
            bookmarkStore: dependencies.bookmarkStore,


            bookmarkMarkDirty: { [dependencies] id in await dependencies.syncEngine.markBookmarkDirty(id) },
            onReadAloud: {
                readerTour?.readAloudTapped()
                startReadAloud()
            },
            onReadAloudFrom: { locator in startReadAloud(from: locator) },
            onFirstContentReady: { await scheduleReaderIndexBackfillIfNeeded() },
            onLoadFailed: { await scheduleReaderIndexBackfillIfNeeded() },
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator,
            sharedPositionJSONString: sharedPositionJSONString,
            reservedPlayerHeight: reservedPlayerHeight,
            pdfViewMode: pdfViewMode?.wrappedValue ?? dependencies.readerDefaults.pdfViewMode,
            pdfViewModeBinding: pdfViewMode,
            keepChromeVisible: startReaderTour
        )


        .ttsErrorAlert(
            state: dependencies.ttsState,
            onRetry: { [weak readAloud] in
                guard let readAloud else { return }
                Task { @MainActor in await readAloud.repeatCurrent() }
            }
        )
        .task {
#if targetEnvironment(macCatalyst)
            if let readerWindowCloseHandle {
                let playbackOwner = dependencies.playbackOwner
                let voiceEntry = voiceEntry
                let host = readAloudHost
                readerWindowCloseHandle.register {
                    await playbackOwner.stop(host: host)
                    await voiceEntry.endForReader()
                }
            }
#endif

            if startReaderTour {
                dependencies.voicePresenter.prewarmVoiceChat(for: vm.book.id, userID: userId)
            }

            // First-content is the preferred boundary for this non-critical
            // work. PDF navigators can legitimately finish their first page
            // without emitting a location callback, so keep a PDF-only
            // fallback. EPUB indexing is intentionally left on the
            // first-content boundary because extraction and embedding can be
            // expensive enough to compete with reader and voice startup.
            if vm.book.formatType == .pdf {
                await scheduleReaderIndexBackfillIfNeeded()
            }

            await runSharedReadingIntegration()


            vm.onUserNavigation = { locator in
                guard let readAloud else { return }
                // Fence late Readium callbacks immediately. Resolving the
                // navigation intent can await paragraph extraction, and an
                // old `.playing` callback must not restore the old resume
                // candidate during that interval.
                readAloud.invalidateReadAloudPositionUpdates()
                Task { @MainActor in
                    readerTour?.userNavigated()
                    let snapshot = readAloud.beginUserNavigationIntent()
                    let destinationParagraphs = await vm.paragraphsForUserNavigationIntent(at: locator)
                    guard let intent = readAloud.resolveUserNavigationIntent(
                        snapshot: snapshot,
                        destinationParagraphs: destinationParagraphs,
                        destinationPage: locator.locations.page
                    ) else {
                        // Superseded by a newer swipe — do not stop; do not consume credit.
                        return
                    }
                    switch intent {
                    case .continuePlaying:
                        readAloud.allowReadAloudPositionUpdates()
                        return
                    case .stopPlaying:
                        vm.clearReadAloudResumeLocator()
                        readAloud.invalidateReadAloudPositionUpdates()
                        await readAloud.stop(preservingPosition: false)
                    }
                }
            }
            vm.onUserNavigationForTTSPagePrefetch = { [weak vm] locator in
                guard let readAloud, readAloud.canPrefetchPageEntry else { return }
                Task { @MainActor [weak vm, weak readAloud] in
                    guard let vm else { return }
                    guard let paragraph = await vm.firstParagraphForPageEntryPrefetch(at: locator) else { return }
                    await readAloud?.prefetchFirstParagraph(paragraph)
                }
            }
            syncBinding = ReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: dependencies.syncEngine
            )




        }
        .onDisappear {
            didScheduleReaderIndexBackfill = false
            syncBinding = nil
            readAloudStartTask?.cancel()
            readAloudStartTask = nil
            readAloudStartRequest = UUID()

            Task { @MainActor [voiceEntry, voicePresenter = dependencies.voicePresenter, viewModel = vm] in
                voicePresenter.cancelPrewarm()
#if !targetEnvironment(macCatalyst)
                await voiceEntry.endForReader()
#endif
                await viewModel.flush()
#if !targetEnvironment(macCatalyst)
                if sharedReadingCoordinator != nil {
                    await dependencies.playbackOwner.setVolume(1)
                }
                await dependencies.playbackOwner.release(host: readAloudHost)
#endif
                readAloud = nil
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !dependencies.voicePresenter.isPresenting {
                IndexingIndicatorChip(
                    bookId: vm.book.id,
                    bookSearch: dependencies.bookSearch
                )
                .padding(.trailing, RishiSpacing.m)
                .padding(.bottom, RishiSpacing.s)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if sharedReadingCoordinator != nil, sharedReadingPeerMesh != nil {
                sharedReadingMicrophoneControls
                    .padding(.leading, RishiSpacing.m)
                    .padding(.bottom, RishiSpacing.s)
            }
        }
        .overlay {
            let voiceActive = dependencies.voicePresenter.isPresenting
            let ttsVisible = readAloud?.showControls == true
            if ReaderAudioChromeVisibility.shouldShow(
                voiceActive: voiceActive,
                ttsVisible: ttsVisible
            ) {
                ReaderAudioChromeOverlay(
                    isVisible: true,
                    mode: voiceActive ? .voice : .tts,
                    ttsState: dependencies.ttsState,
                    voiceState: dependencies.voicePresenter.state,
                    readAloud: readAloud,
                    onOpenVoiceChat: {
                        Task {
                            let controller = ensureReadAloudController()
                            await controller.pauseForVoiceHandoff()
                            voiceEntry.presentVoice(
                                bookId: vm.book.id,
                                context: vm.voiceContext(),
                                contextProvider: { await vm.liveVoiceContext() },
                                initialQuote: nil
                            )
                        }
                    },
                    onOpenReadAloud: {
                        Task {
                            await dependencies.voicePresenter.requestEnd()
                            let controller = ensureReadAloudController()
                            if dependencies.playbackOwner.activeController === controller {
                                await controller.openReadAloudFromVoice(vm: vm)
                            } else {
                                _ = await dependencies.playbackOwner.start(
                                    controller: controller,
                                    reader: vm,
                                    host: readAloudHost
                                )
                            }
                        }
                    },
                    onEndVoice: {
                        Task {
                            await dependencies.voicePresenter.dismissVoiceChrome()
                            await readAloud?.resumeAfterVoiceIfNeeded()
                        }
                    },
                    onOpenTextChat: { showVoiceTextChat = true },
                )
            }
        }
        .overlay(alignment: .top) {
            if let readerTour {
                ReaderOnboardingTourOverlay(coordinator: readerTour)
                    .padding(.top, RishiSpacing.m)
            }
        }
        .sheet(isPresented: $showVoiceTextChat) {
            NavigationStack {
                if let voiceTextVM {
                    ChatPanelView(
                        viewModel: voiceTextVM,
                        initialQuote: dependencies.voicePresenter.pendingInitialQuote
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: dependencies.voicePresenter.currentBookId) {
                voiceTextVM = nil
                if let convo = try? await dependencies.conversationLookup.findOrCreate(
                    userId: userId,
                    bookId: dependencies.voicePresenter.currentBookId
                ) {
                    voiceTextVM = ChatPanelViewModel.make(
                        conversation: convo,
                        chatService: dependencies.chatService,
                        messageStore: dependencies.messageStore
                    )
                }
            }
        }
        .onChange(of: dependencies.voicePresenter.pendingInitialQuote) { _, quote in
            if quote != nil {
                showVoiceTextChat = true
            }
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: dependencies.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        Task { await ra.applySettings(settings) }
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(
            item: $pendingNarrationUpgradePrompt,
            onDismiss: {
                if let token = pendingNarrationUpgradeSessionToken {
                    dependencies.ttsState.clearPreservedFailure(ifCurrent: token)
                }
                pendingNarrationUpgradeSessionToken = nil
                forwardPaywallRequestIfNeeded()
            }
        ) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    paywallRequestHandoff.queue("narration_exhausted")
                    pendingNarrationUpgradePrompt = nil
                },
                onDismiss: {
                    pendingNarrationUpgradePrompt = nil
                    if let token = pendingNarrationUpgradeSessionToken {
                        dependencies.ttsState.clearPreservedFailure(ifCurrent: token)
                    }
                    pendingNarrationUpgradeSessionToken = nil
                }
            )
        }
        .sheet(item: Binding(
            get: { voiceEntry.pendingUpgradePrompt },
            set: { newValue in if newValue == nil { voiceEntry.dismissUpgradePrompt() } }
        ), onDismiss: {
            forwardPaywallRequestIfNeeded()
        }) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    paywallRequestHandoff.queue("voice_chat_exhausted")
                    voiceEntry.dismissUpgradePrompt()
                },
                onDismiss: { voiceEntry.dismissUpgradePrompt() }
            )
        }
    }

    private var reservedPlayerHeight: CGFloat {
        vm.book.formatType == .epub ? Self.playerReservationHeight : 0
    }

    @MainActor
    private func runSharedReadingIntegration() async {
        guard let sharedReadingCoordinator, let sharedReadingJoin else { return }
        var lastRemoteSequence: Int64 = -1
        var lastSentPosition: String?
        var lastSentPlaying: Bool?
        let settings = await dependencies.ttsSettingsStore.load(userId: userId)
        while !Task.isCancelled {
            let snapshot = await sharedReadingCoordinator.snapshot()
            let isTTSPlaying = readAloud?.isActivelySpeaking == true || dependencies.ttsState.status == .playing
            sharedTTSIsPlaying = isTTSPlaying
            await dependencies.playbackOwner.setVolume(
                SharedReadingAudioDucking.ttsVolume(
                    isTTSPlaying: isTTSPlaying,
                    speakerUserId: snapshot.speakerUserId
                )
            )
            let floorGranted = snapshot.speakerUserId == userId.uuidString
            sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setSpeakerFloorGranted(floorGranted, in: sharedMicrophonePolicy)
            if !isTTSPlaying, floorGranted {
                try? await sharedReadingCoordinator.releaseSpeaker()
            }
            await sharedReadingPeerMesh?.setMicrophoneEnabled(
                sharedMicrophonePolicy.microphoneEnabled(isTTSPlaying: isTTSPlaying)
            )
            if snapshot.currentParticipantUserId != userId.uuidString,
               let progress = snapshot.latestProgress,
               progress.sequence > lastRemoteSequence,
               progress.bookId == sharedReadingJoin.response.book.bookId,
               progress.contentHash == sharedReadingJoin.response.book.contentHash {
                lastRemoteSequence = progress.sequence
                sharedPositionJSONString = progress.position
                if progress.isPlaying, let locator = try? Locator(jsonString: progress.position) {
                    startReadAloud(from: locator)
                } else if !progress.isPlaying {
                    await readAloud?.pause()
                }
            }

            if snapshot.status == .active,
               snapshot.currentParticipantUserId == userId.uuidString,
               let locator = vm.latestLocator,
               let position = try? ReaderPositionLocator(locator: locator).encodedJSONString() {
                let isPlaying = isTTSPlaying
                if position != lastSentPosition || isPlaying != lastSentPlaying {
                    sharedSequence &+= 1
                    let progress = SharedReadingProgress(
                        sessionId: sharedReadingJoin.response.sessionId,
                        bookId: sharedReadingJoin.response.book.bookId,
                        contentHash: sharedReadingJoin.response.book.contentHash,
                        format: sharedReadingJoin.response.book.format,
                        sequence: sharedSequence,
                        position: position,
                        isPlaying: isPlaying,
                        ttsRate: settings.speed,
                        updatedAt: Date()
                    )
                    do {
                        try await sharedReadingCoordinator.sendControllerSyncFrame(progress)
                        lastSentPosition = position
                        lastSentPlaying = isPlaying
                    } catch {
                        // Keep the position dirty so the next reconnect or
                        // coordinator tick retries the authoritative frame.
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @ViewBuilder
    private var sharedReadingMicrophoneControls: some View {
        HStack(spacing: 8) {
            Button {
                sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setMuted(
                    !sharedMicrophonePolicy.userMuted,
                    in: sharedMicrophonePolicy
                )
                applySharedMicrophonePolicy()
            } label: {
                Label(
                    sharedMicrophonePolicy.userMuted ? "Unmute" : "Mute",
                    systemImage: sharedMicrophonePolicy.userMuted ? "mic.slash.fill" : "mic.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            if sharedTTSIsPlaying {
                Text("Hold to speak")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in setSharedHoldToTalk(true) }
                            .onEnded { _ in setSharedHoldToTalk(false) }
                    )
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
    }

    private func setSharedHoldToTalk(_ holding: Bool) {
        guard sharedTTSIsPlaying else { return }
        sharedMicrophonePolicy = SharedReadingMicrophonePolicy.setHoldToTalk(holding, in: sharedMicrophonePolicy)
        if let sharedReadingCoordinator {
            Task {
                if holding {
                    try? await sharedReadingCoordinator.requestSpeaker()
                } else {
                    try? await sharedReadingCoordinator.releaseSpeaker()
                }
            }
        }
        applySharedMicrophonePolicy()
    }

    private func applySharedMicrophonePolicy() {
        guard let sharedReadingPeerMesh else { return }
        let enabled = sharedMicrophonePolicy.microphoneEnabled(isTTSPlaying: sharedTTSIsPlaying)
        Task { await sharedReadingPeerMesh.setMicrophoneEnabled(enabled) }
    }

    @MainActor
    private func forwardPaywallRequestIfNeeded() {
        guard let request = paywallRequestHandoff.takeAfterPromptDismissal() else { return }
        onRequestPaywall(request)
    }

    @MainActor
    private func ensureReadAloudController() -> ReadAloudController {
        if let readAloud { return readAloud }
        let controller = dependencies.playbackOwner.makeController(
            userId: userId,
            bookFileStorage: dependencies.bookFileStorage,
            onAllowanceFailure: { failure, sessionToken in
                pendingNarrationUpgradePrompt = readAloudUpgradeReason(for: failure)
                pendingNarrationUpgradeSessionToken = sessionToken
            },
            onReadAloudPositionChange: { locator in
                vm.didChangeReadAloudLocation(locator)
            },
            onPersistReadAloudPosition: { locator in
                vm.didChangeReadAloudLocation(locator)
                await vm.flush()
            },
            onFirstUtteranceFinished: { [weak readerTour] in
                readerTour?.firstUtteranceFinished()
            },
            onFirstUtteranceFailed: { [weak readerTour] in
                readerTour?.readAloudFailed()
            }
        )
        readAloud = controller
        return controller
    }

    @MainActor
    private func startReadAloud(from startLocator: Locator? = nil) {
        readAloudStartTask?.cancel()
        let request = UUID()
        readAloudStartRequest = request
        readAloudStartTask = Task { @MainActor in
            defer {
                if readAloudStartRequest == request {
                    readAloudStartTask = nil
                }
            }
            if let reason = await EntitlementAIGate.gateAIFeature(
                .narration,
                store: dependencies.entitlementSnapshotStore,
                coordinator: dependencies.entitlementRefreshCoordinator
            ) {
                pendingNarrationUpgradePrompt = reason
                readerTour?.readAloudFailed()
                return
            }

            guard !Task.isCancelled, readAloudStartRequest == request else {
                return
            }

            let controller = ensureReadAloudController()
            let started = await dependencies.playbackOwner.start(
                controller: controller,
                reader: vm,
                host: readAloudHost,
                from: startLocator
            )
            if !started { readerTour?.readAloudFailed() }
        }
    }

    @MainActor
    private func scheduleReaderIndexBackfillIfNeeded() async {
        guard !didScheduleReaderIndexBackfill else { return }
        guard await dependencies.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex else {
            return
        }
        didScheduleReaderIndexBackfill = true
        let url = dependencies.bookFileStorage.absoluteFileURL(for: vm.book)
        await dependencies.indexingHook.scheduleIndexing(for: vm.book, fileURL: url)
    }
}

func readAloudUpgradeReason(for failure: WorkerAllowanceError) -> AIFeatureBlockReason {
    failure.kind == .trial ? .trialExhausted : .narrationAllowanceExhausted
}

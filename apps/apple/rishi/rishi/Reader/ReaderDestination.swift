import SwiftUI
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
            ttsPrewarmer: services.audio.ttsPrewarmer
        )
    }
}












struct ReaderDestination: View {
    let dependencies: ReaderDestinationDependencies
    let userId: UserID
    let onRequestPaywall: (String) -> Void
    let pdfViewMode: Binding<PDFViewModeSetting>?

    @State private var readAloudStartTask: Task<Void, Never>?
    @State private var readAloudStartRequest = UUID()
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?

    @State private var voiceEntry: ReaderVoiceEntry
    @State private var showVoiceTextChat = false
    @State private var voiceTextVM: ChatPanelViewModel?

    init(
        vm: ReaderViewModel,
        dependencies: ReaderDestinationDependencies,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil
    ) {
        let peeked = dependencies.readerSettingsStore.peekPersistedTheme(for: vm.book.id)
        let initial = peeked ?? dependencies.readerDefaults.theme
        vm.theme = initial

        self._vm = State(initialValue: vm)
        self.dependencies = dependencies
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self.pdfViewMode = pdfViewMode
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: dependencies.voicePresenter,
            voiceLanguageProvider: { dependencies.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: dependencies.entitlementSnapshotStore,
            onRequestPaywall: onRequestPaywall
        ))
    }

    var body: some View {
        ReaderScreen(
            viewModel: vm,
            appDefaultTheme: dependencies.readerDefaults.theme,
            readerSettingsStore: dependencies.readerSettingsStore,
            highlightStore: dependencies.highlightStore,
            bookmarkStore: dependencies.bookmarkStore,


            bookmarkMarkDirty: { [dependencies] id in await dependencies.syncEngine.markBookmarkDirty(id) },
            onReadAloud: { startReadAloud() },
            onReadAloudFrom: { locator in startReadAloud(from: locator) },
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator,
            pdfViewMode: pdfViewMode?.wrappedValue ?? dependencies.readerDefaults.pdfViewMode,
            pdfViewModeBinding: pdfViewMode
        )


        .ttsErrorAlert(state: dependencies.ttsState)
        .task {



            vm.onUserNavigation = { locator in
                Task { @MainActor in
                    guard let readAloud else { return }
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
                        return
                    case .stopPlaying:
                        await readAloud.stop()
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




            if await dependencies.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex {
                let url = dependencies.bookFileStorage.absoluteFileURL(for: vm.book)
                await dependencies.indexingHook.scheduleIndexing(for: vm.book, fileURL: url)
            }
        }
        .onDisappear {
            syncBinding = nil
            readAloudStartTask?.cancel()
            readAloudStartTask = nil
            readAloudStartRequest = UUID()

            let controller = readAloud
            let readAloudBinding = $readAloud
            Task { @MainActor [controller, voicePresenter = dependencies.voicePresenter, readAloudBinding] in
                await voicePresenter.parkSession()
                await controller?.stop()
                controller?.dispose()
                if let controller,
                   let current = readAloudBinding.wrappedValue,
                   current === controller {
                    readAloudBinding.wrappedValue = nil
                }
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
                            await ensureReadAloudController().openReadAloudFromVoice(vm: vm)
                        }
                    },
                    onEndVoice: {
                        Task {
                            await dependencies.voicePresenter.dismissVoiceChrome()
                            await readAloud?.resumeAfterVoiceIfNeeded()
                        }
                    },
                    onOpenTextChat: { showVoiceTextChat = true }
                )
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
        .sheet(item: $pendingNarrationUpgradePrompt) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    pendingNarrationUpgradePrompt = nil
                    onRequestPaywall("narration_exhausted")
                },
                onDismiss: { pendingNarrationUpgradePrompt = nil }
            )
        }
        .sheet(item: Binding(
            get: { voiceEntry.pendingUpgradePrompt },
            set: { newValue in if newValue == nil { voiceEntry.dismissUpgradePrompt() } }
        )) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    voiceEntry.dismissUpgradePrompt()
                    onRequestPaywall("voice_chat_exhausted")
                },
                onDismiss: { voiceEntry.dismissUpgradePrompt() }
            )
        }
    }

    @MainActor
    private func ensureReadAloudController() -> ReadAloudController {
        if let readAloud { return readAloud }
        let controller = ReadAloudController(
            ttsEngine: dependencies.ttsEngine,
            ttsState: dependencies.ttsState,
            ttsSettingsStore: dependencies.ttsSettingsStore,
            ttsPrewarmer: dependencies.ttsPrewarmer,
            ttsPresence: dependencies.ttsPresenceController,
            coordidator: dependencies.ttsCoordinator,
            userId: userId,
            nowPlayingController: dependencies.nowPlayingController,
            bookFileStorage: dependencies.bookFileStorage,
            onAllowanceFailure: { failure in
                pendingNarrationUpgradePrompt = readAloudUpgradeReason(for: failure)
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
                return
            }

            guard !Task.isCancelled, readAloudStartRequest == request else {
                return
            }

            let controller = ensureReadAloudController()
            if let startLocator {
                await controller.startReader(vm: vm, from: startLocator)
            } else {
                await controller.startReader(vm: vm)
            }
        }
    }
}

func readAloudUpgradeReason(for failure: WorkerAllowanceError) -> AIFeatureBlockReason {
    failure.kind == .trial ? .trialExhausted : .narrationAllowanceExhausted
}

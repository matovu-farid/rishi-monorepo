import SwiftUI
import ReadiumShared












struct ReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void
    let pdfViewMode: Binding<PDFViewModeSetting>?

    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?

    @State private var voiceEntry: ReaderVoiceEntry
    @State private var showVoiceTextChat = false
    @State private var voiceTextVM: ChatPanelViewModel?

    init(
        vm: ReaderViewModel,
        services: BootstrappedServices,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil
    ) {
        let peeked = services.library.readerSettingsStore.peekPersistedTheme(for: vm.book.id)
        let initial = peeked ?? services.readerDefaults.theme
        vm.theme = initial
        if peeked == nil {
            let store = services.library.readerSettingsStore
            let bookId = vm.book.id
            let seed = initial
            Task {
                if store.peekPersistedTheme(for: bookId) == nil {
                    await store.setTheme(seed, for: bookId)
                }
            }
        }

        self._vm = State(initialValue: vm)
        self.services = services
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self.pdfViewMode = pdfViewMode
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            voiceLanguageProvider: { services.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
            entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
            onRequestPaywall: onRequestPaywall
        ))
    }

    var body: some View {
        ReaderScreen(
            viewModel: vm,
            appDefaultTheme: services.readerDefaults.theme,
            readerSettingsStore: services.library.readerSettingsStore,
            highlightStore: services.library.highlightStore,
            bookmarkStore: services.library.bookmarkStore,


            bookmarkMarkDirty: { [services] id in await services.sync.engine.markBookmarkDirty(id) },
            onReadAloud: {
                Task {
                    if let reason = await EntitlementAIGate.gateAIFeature(
                        .narration,
                        store: services.billing.entitlementSnapshotStore,
                        coordinator: services.billing.entitlementRefreshCoordinator
                    ) {
                        pendingNarrationUpgradePrompt = reason
                        return
                    }

                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            ttsPresence: services.ttsPresenceController,
                            coordidator: services.audioCoordinator,
                            userId: userId,
                            nowPlayingController: services.nowPlayingController,
                            bookFileStorage: services.library.bookFileStorage
                        )
                    }
                    await readAloud?.startReader(vm: vm)
                }
            } ,
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator,
            pdfViewMode: pdfViewMode?.wrappedValue ?? services.readerDefaults.pdfViewMode,
            pdfViewModeBinding: pdfViewMode
        )


        .ttsErrorAlert(state: services.ttsState)
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
                syncEngine: services.sync.engine
            )




            if await services.library.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex {
                let url =  services.library.bookFileStorage.absoluteFileURL(for: vm.book)
                await services.library.indexingHook.scheduleIndexing(for: vm.book, fileURL: url)
            }
        }
        .onDisappear {
            syncBinding = nil

            Task {
                await services.voicePresenter.parkSession()
                await readAloud?.stop()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !services.voicePresenter.isPresenting {
                IndexingIndicatorChip(
                    bookId: vm.book.id,
                    bookSearch: services.library.bookSearch
                )
                .padding(.trailing, RishiSpacing.m)
                .padding(.bottom, RishiSpacing.s)
            }
        }
        .overlay {
            let voiceActive = services.voicePresenter.isPresenting
            let ttsVisible = readAloud?.showControls == true
            if ReaderAudioChromeVisibility.shouldShow(
                voiceActive: voiceActive,
                ttsVisible: ttsVisible
            ) {
                ReaderAudioChromeOverlay(
                    isVisible: true,
                    mode: voiceActive ? .voice : .tts,
                    ttsState: services.ttsState,
                    voiceState: services.voicePresenter.state,
                    readAloud: readAloud,
                    onOpenVoiceChat: {
                        Task {
                            let controller = ensureReadAloudController()
                            await controller.pauseForVoiceHandoff()
                            voiceEntry.presentVoice(
                                bookId: vm.book.id,
                                context: vm.voiceContext(),
                                initialQuote: nil
                            )
                        }
                    },
                    onOpenReadAloud: {
                        Task {
                            await services.voicePresenter.requestEnd()
                            await ensureReadAloudController().openReadAloudFromVoice(vm: vm)
                        }
                    },
                    onEndVoice: {
                        Task {
                            await services.voicePresenter.dismissVoiceChrome()
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
                        initialQuote: services.voicePresenter.pendingInitialQuote
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: services.voicePresenter.currentBookId) {
                voiceTextVM = nil
                if let convo = try? await services.conversationLookup.findOrCreate(
                    userId: userId,
                    bookId: services.voicePresenter.currentBookId
                ) {
                    voiceTextVM = ChatPanelViewModel.make(
                        conversation: convo,
                        services: services
                    )
                }
            }
        }
        .onChange(of: services.voicePresenter.pendingInitialQuote) { _, quote in
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
                    store: services.ttsSettingsStore,
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
            ttsEngine: services.ttsEngine,
            ttsState: services.ttsState,
            ttsSettingsStore: services.ttsSettingsStore,
            ttsPrewarmer: services.ttsPrewarmer,
            ttsPresence: services.ttsPresenceController,
            coordidator: services.audioCoordinator,
            userId: userId,
            nowPlayingController: services.nowPlayingController,
            bookFileStorage: services.library.bookFileStorage
        )
        readAloud = controller
        return controller
    }
}

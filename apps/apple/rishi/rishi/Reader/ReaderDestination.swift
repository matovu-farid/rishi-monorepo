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

    @State private var readAloudStartTask: Task<Void, Never>?
    @State private var readAloudStartRequest = UUID()
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    private let readAloudHost = UUID()
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?
    @State private var pendingNarrationUpgradeSessionToken: UUID?
    @State private var paywallRequestHandoff = ReaderPaywallRequestHandoff()

    @State private var voiceEntry: ReaderVoiceEntry
    @State private var readerTour: ReaderOnboardingTourCoordinator?
    @State private var showVoiceTextChat = false
    @State private var voiceTextVM: ChatPanelViewModel?

    init(
        vm: ReaderViewModel,
        dependencies: ReaderDestinationDependencies,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void,
        startReaderTour: Bool = false,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil
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
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator,
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

            if startReaderTour {
                dependencies.voicePresenter.prewarmVoiceChat(for: vm.book.id, userID: userId)
            }


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

            Task { @MainActor [voicePresenter = dependencies.voicePresenter, viewModel = vm] in
                voicePresenter.cancelPrewarm()
                await voicePresenter.parkSession()
                await viewModel.flush()
                await dependencies.playbackOwner.release(host: readAloudHost)
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
                    onOpenTextChat: { showVoiceTextChat = true }
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
}

func readAloudUpgradeReason(for failure: WorkerAllowanceError) -> AIFeatureBlockReason {
    failure.kind == .trial ? .trialExhausted : .narrationAllowanceExhausted
}

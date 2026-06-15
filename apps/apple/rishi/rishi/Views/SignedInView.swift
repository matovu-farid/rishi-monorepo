//
//  SignedInView.swift
//  rishi
//
//  Extracted from RootView (refactor). Owns the entire signed-in composition:
//  library NavigationStack, reader destinations, all signed-in sheets
//  (chat, paywall, settings), read-aloud controls overlay, deep-link
//  wiring, scene-restoration task, and Mac-command intent dispatch.
//
//  RootView retains only the auth-switch branch (loading / signed-in /
//  signed-out) and the onboarding cover which spans both auth states.
//

import SwiftUI
import RishiCore
import RishiAudio
import RishiAuth
import RishiBilling
import RishiChat
import RishiLibrary
import RishiOnboarding
import RishiReader
import RishiSettings
import RishiUIKit
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Helper types (relocated from RootView)

/// reader-tts-xml-and-loading fix — memoizes reader view-models per book id
/// across SignedInView body recomputes.
///
/// The reader VMs (`PDFReaderViewModel` / `EPUBReaderViewModel`) carry the
/// loaded document/publication and the `.loaded` `loadingState`. They were
/// previously constructed as plain `let` locals inside the `@ViewBuilder`
/// destination functions, so every body recompute (e.g. tapping
/// Read Aloud, which mutates `showTTSControls` / `readerTTSBridge` @State)
/// minted a fresh `.idle` VM and handed it to the structurally-identical
/// reader screen — re-showing the stuck "Opening {book}" cold-open overlay
/// and detaching the TTS controls sheet from the live VM.
///
/// This cache is held in SignedInView `@State` (stable reference identity), so
/// the destination functions reuse the same VM instance for a given book id.
/// Entries are dropped on reader dismiss via `drop(_:)` so reopening a book
/// re-reads its persisted position from scratch.
@MainActor
final class ReaderViewModelCache {
    private var pdfVMs: [BookID: PDFReaderViewModel] = [:]
    private var epubVMs: [BookID: EPUBReaderViewModel] = [:]

    func pdf(for id: BookID, make: () -> PDFReaderViewModel) -> PDFReaderViewModel {
        if let existing = pdfVMs[id] { return existing }
        let vm = make()
        pdfVMs[id] = vm
        return vm
    }

    func epub(for id: BookID, make: () -> EPUBReaderViewModel) -> EPUBReaderViewModel {
        if let existing = epubVMs[id] { return existing }
        let vm = make()
        epubVMs[id] = vm
        return vm
    }

    func drop(_ id: BookID) {
        pdfVMs.removeValue(forKey: id)
        epubVMs.removeValue(forKey: id)
    }
}

struct SignedInView: View {

    let services: BootstrappedServices
    let user: User
    /// Bindings to the @SceneStorage cells owned by RootView.
    @Binding var selectedTabRaw: String
    @Binding var openBookIdRaw: String
    /// Called when the user signs out from the Settings sheet.
    let onSignedOut: () -> Void
    /// Called with the resolved user id so the composition root can update
    /// its cached user id seam (AppDependencies.cachedUserId) without
    /// SignedInView referencing AppDependencies directly. Fired inside the
    /// `.task(id: user.id)` attached to the library NavigationStack.
    let onCacheUserId: (UserID) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.macCommandRouter) private var commandRouter

    init(
        services: BootstrappedServices,
        user: User,
        selectedTabRaw: Binding<String>,
        openBookIdRaw: Binding<String>,
        onSignedOut: @escaping () -> Void,
        onCacheUserId: @escaping (UserID) -> Void
    ) {
        self.services = services
        self.user = user
        self._selectedTabRaw = selectedTabRaw
        self._openBookIdRaw = openBookIdRaw
        self.onSignedOut = onSignedOut
        self.onCacheUserId = onCacheUserId
        let userId = user.id
        self._libraryVM = State(initialValue: LibraryViewModel(
            bookStore: services.bookStore,
            positionStore: services.positionStore,
            storage: services.bookFileStorage,
            currentUserId: { userId }
        ))
    }

    // MARK: - Signed-in @State

    /// Owned by this view so LibraryViewModel lifecycle matches the
    /// authenticated session. Injected into the environment for
    /// LibraryRootView and other signed-in consumers via .environment(libraryVM).
    @State private var libraryVM: LibraryViewModel

    /// Phase 8 (TTS) — read-aloud controller. Created once the user opens
    /// a reader and taps Read Aloud for the first time.
    @State private var readAloud: ReadAloudController? = nil

    /// Phase 9 (Chat) — drives the .sheet(item:) for conversations-list tap.
    @State private var selectedConversation: Conversation? = nil

    /// BILL-04 — non-nil while the paywall sheet is presented.
    @State private var paywallFeature: PaywallFeature? = nil

    /// SYNC-08 — Settings sheet entry point.
    @State private var showSettings = false

    /// Phase 20 perf — transient hint cache keyed by BookID, populated on
    /// every push that had the full Book in hand so NavigationLazyBook can
    /// paint first frame without a fresh bookStore round-trip.
    @State private var bookHints: [BookID: Book] = [:]

    /// SYNC-03 — bridges polling position changes to SyncEngine. Cleared on
    /// reader dismiss so the poll task cancels via deinit.
    @State private var pdfSyncBinding: PDFReaderPositionSyncBinding? = nil
    @State private var epubSyncBinding: EPUBReaderPositionSyncBinding? = nil

    /// reader-tts-xml-and-loading fix — memoizes reader VMs across body
    /// recomputes so a ReadAloud @State flip doesn't recreate a fresh .idle VM.
    @State private var readerVMCache = ReaderViewModelCache()

    /// Guards the scene-restoration .task so we don't re-run it on every
    /// body refresh. (Moved from RootView because it is signed-in-only logic.)
    @State private var sceneRestored = false

    // MARK: - Body

    var body: some View {
        libraryTab(
            services: services,
            user: user,
            onShowChats: { router.showConversations() }
        )
        .environment(libraryVM)
        .sheet(item: $selectedConversation) { convo in
            ConversationChatHost(
                conversation: convo,
                services: services,
                onFreeUserTap: {
                    paywallFeature = PaywallFeature(name: "Voice Chat")
                }
            )
        }
        .sheet(
            item: Binding(
                get: { services.chatPresenter.pendingPresentation },
                set: { newValue in
                    if newValue == nil {
                        services.chatPresenter.clear()
                    }
                }
            )
        ) { pending in
            ChatPanelHostView(
                pending: pending,
                userId: user.id,
                services: services,
                onFreeUserTap: {
                    paywallFeature = PaywallFeature(name: "Voice Chat")
                }
            )
        }
        // BILL-04 — paywall sheet.
        .sheet(item: $paywallFeature) { feature in
            PaywallHost(
                feature: feature,
                services: services,
                onDismiss: { paywallFeature = nil }
            )
        }
        // Phase 12 Plan 12-03 — deep-link dispatch via AppRouter.
        .onOpenURL { url in
            router.onBookResolved = { book in
                bookHints[book.id] = book
            }
            router.onConversationResolved = { convo in
                selectedConversation = convo
            }
            router.onFileURL = { [libraryVM] fileURL in
                Task {
                    _ = await services.importCoordinator.importBooks([fileURL])
                    await libraryVM.refresh()
                }
            }
            router.handle(
                url: url,
                bookStore: services.bookStore,
                conversationStore: services.conversationStore
            )
        }
        // Phase 12 Plan 12-01 — drain the Mac command router on every intent change.
        .task(id: commandRouter?.pendingIntent) {
            consumePendingMacIntent()
        }
        // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader cover.
        .task {
            guard !sceneRestored else { return }
            sceneRestored = true
            router.onBookResolved = { book in
                bookHints[book.id] = book
            }
            await router.applyRestored(
                tabRaw: selectedTabRaw,
                openBookIdRaw: openBookIdRaw,
                bookStore: services.bookStore
            )
        }
        // Persist the latest scene state on every visible path change.
        .onChange(of: router.path) { _, _ in
            let cells = router.persistCells()
            selectedTabRaw = cells.tabRaw
            openBookIdRaw  = cells.openBookIdRaw
        }
    }

    // MARK: - Mac command intent dispatch (Phase 12 Plan 12-01)

    private func consumePendingMacIntent() {
        guard let cmdRouter = commandRouter, let intent = cmdRouter.pendingIntent else { return }
        defer { cmdRouter.consume() }

        switch intent {
        case .importBook:
            router.showLibraryRoot()
            NotificationCenter.default.post(name: RishiCommand.importBook, object: nil)

        case .newConversation:
            router.showConversations()

        case .focusSearch:
            router.showLibraryRoot()
            NotificationCenter.default.post(name: RishiCommand.focusSearch, object: nil)

        case .fontIncrease:
            NotificationCenter.default.post(
                name: RishiCommand.fontStep, object: nil,
                userInfo: [RishiCommand.fontStepDeltaKey: +1]
            )

        case .fontDecrease:
            NotificationCenter.default.post(
                name: RishiCommand.fontStep, object: nil,
                userInfo: [RishiCommand.fontStepDeltaKey: -1]
            )

        case .selectTheme(let macTheme):
            services.readerDefaults.theme = mapReaderTheme(macTheme)

        case .selectTab(let tab):
            switch tab {
            case .library: router.showLibraryRoot()
            case .chats:   router.showConversations()
            }

        case .pageForward:
            NotificationCenter.default.post(name: RishiCommand.pageForward, object: nil)

        case .pageBackward:
            NotificationCenter.default.post(name: RishiCommand.pageBackward, object: nil)
        }
    }

    private func mapReaderTheme(_ macTheme: MacReaderTheme) -> ReaderTheme {
        switch macTheme {
        case .light: return .light
        case .sepia: return .sepia
        case .dark:  return .dark
        }
    }

    // MARK: - Library tab

    @ViewBuilder
    private func libraryTab(
        services: BootstrappedServices,
        user: User,
        onShowChats: (() -> Void)? = nil
    ) -> some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
                path: bindableRouter.path,
                importCoordinator: services.importCoordinator,
                onOpenBook: { book in
                    bookHints[book.id] = book
                    router.path.append(ReaderRoute.route(for: book))
                },
                onShowSettings: { showSettings = true },
                onShowChats: onShowChats,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first else { return }
                    bookHints[book.id] = book
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                destinationView(for: route, services: services, userId: user.id)
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                conversationsDestination(services: services, user: user)
            }
            .task(id: user.id) {
                onCacheUserId(user.id)
                async let sample = services.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                async let reader = services.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
                _ = await (sample, reader)
                await libraryVM.refresh()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                services: services,
                user: user,
                onSignedOut: onSignedOut
            )
        }
    }

    /// Conversations list pushed onto the Library NavigationStack.
    @ViewBuilder
    private func conversationsDestination(services: BootstrappedServices, user: User) -> some View {
        ConversationsListHost(
            services: services,
            userId: user.id,
            onSelect: { convo in selectedConversation = convo }
        )
    }

    // MARK: - Navigation destinations

    @ViewBuilder
    private func destinationView(for route: ReaderRoute,
                                 services: BootstrappedServices,
                                 userId: UserID) -> some View {
        switch route {
        case .pdf(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], bookStore: services.bookStore) { book in
                pdfReaderDestination(book: book, services: services, userId: userId)
            }
        case .epub(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], bookStore: services.bookStore) { book in
                epubReaderDestination(book: book, services: services, userId: userId)
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], bookStore: services.bookStore) { book in
                EpubPlaceholderView(book: book) {
                    if !router.path.isEmpty { router.path.removeLast() }
                }
            }
        }
    }

    @ViewBuilder
    private func pdfReaderDestination(book: Book,
                                      services: BootstrappedServices,
                                      userId: UserID) -> some View {
        let pdfVM = readerVMCache.pdf(for: book.id) {
            PDFReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: services.positionStore
            )
        }
        PDFReaderScreen(
                viewModel: pdfVM,
                readerSettingsStore: services.readerSettingsStore,
                highlightStore: services.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    Task {
                        let level = await services.entitlementService.snapshot()
                        guard level == .pro else {
                            paywallFeature = PaywallFeature(name: "Read Aloud")
                            return
                        }
                        if readAloud == nil {
                            readAloud = ReadAloudController(
                                ttsEngine: services.ttsEngine,
                                ttsState: services.ttsState,
                                ttsSettingsStore: services.ttsSettingsStore,
                                ttsPrewarmer: services.ttsPrewarmer,
                                userId: userId
                            )
                        }
                        await readAloud?.startPDF(vm: pdfVM)
                    }
                } : nil,
                chatPresenter: services.chatPresenter,
                readAloudParagraph: readAloud?.currentParagraph
            )
            .task {
                pdfSyncBinding = PDFReaderPositionSyncBinding(
                    viewModel: pdfVM,
                    syncEngine: services.syncEngine
                )
            }
            .onDisappear {
                pdfSyncBinding = nil
                readerVMCache.drop(book.id)
                Task { await readAloud?.stop() }
            }
            .overlay(alignment: .bottom) {
                readAloudControlsOverlay(services: services)
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
                            ra.showPicker = false
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
    }

    @ViewBuilder
    private func epubReaderDestination(book: Book,
                                       services: BootstrappedServices,
                                       userId: UserID) -> some View {
        let epubVM = readerVMCache.epub(for: book.id) {
            EPUBReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: services.positionStore
            )
        }
        EPUBReaderScreen(
            viewModel: epubVM,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? {
                Task {
                    let level = await services.entitlementService.snapshot()
                    var entitled = level == .pro
                    #if DEBUG
                    if UITestBypass.isActive { entitled = true }
                    #endif
                    guard entitled else {
                        paywallFeature = PaywallFeature(name: "Read Aloud")
                        return
                    }
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            userId: userId
                        )
                    }
                    await readAloud?.startEPUB(vm: epubVM)
                }
            } : nil,
            chatPresenter: services.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            epubVM.onUserNavigation = { _ in
                Task { await readAloud?.stop() }
            }
            epubSyncBinding = EPUBReaderPositionSyncBinding(
                viewModel: epubVM,
                syncEngine: services.syncEngine
            )
        }
        .onDisappear {
            epubSyncBinding = nil
            readerVMCache.drop(book.id)
            Task { await readAloud?.stop() }
        }
        .overlay(alignment: .bottom) {
            readAloudControlsOverlay(services: services)
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
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Read Aloud overlay (Phase 8)

    @ViewBuilder
    private func readAloudControlsOverlay(services: BootstrappedServices) -> some View {
        if let ra = readAloud, ra.showControls, let bridge = ra.bridge {
            ReadAloudControlsView(
                state: services.ttsState,
                onPlayPause: {
                    Task {
                        if services.ttsState.status == .playing {
                            await bridge.pause()
                        } else {
                            await bridge.resume()
                        }
                    }
                },
                onStop: {
                    Task { await ra.stop() }
                },
                onOpenPicker: {
                    ra.showPicker = true
                },
                onPreviousParagraph: {
                    Task { await bridge.previous() }
                },
                onNextParagraph: {
                    Task { await bridge.next() }
                },
                onRepeatParagraph: {
                    Task { await bridge.repeatCurrent() }
                }
            )
            .modifier(GlassCardBackground(cornerRadius: RishiRadius.large))
            .shadow(radius: RishiSpacing.s)
            .padding(.horizontal, RishiSpacing.m)
            .padding(.bottom, RishiSpacing.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: ra.showControls)
        }
    }

    // MARK: - Helpers

    private func pdfFileURL(for book: Book) -> URL {
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return documentsURL.appendingPathComponent(book.fileURL)
    }
}

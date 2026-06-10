//
//  RootView.swift
//  rishi
//
//  Phase 4 Plan 04-06 — top-level view gating Library vs DebugAuth on the
//  current authenticated user.
//  Phase 5 Plan 05-07 — presents PDFReaderScreen as a full-screen cover
//  when the user taps a .pdf book in the library; .epub books route to
//  an explicit placeholder until Phase 6.
//  Phase 6 Plan 06-06 — .epub now opens EPUBReaderScreen for real;
//  .mobi / .azw3 keep routing to the placeholder until a future phase
//  adds a converter.
//
//  The reader is mounted as a full-screen cover (not a navigationDestination)
//  because LibraryRootView owns its own NavigationStack. Nesting another
//  NavigationStack causes split-view weirdness on iPad / Catalyst.
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
#if canImport(PDFKit)
import PDFKit
#endif

struct RootView: View {

    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps
    @Environment(LibraryViewModel.self) private var libraryViewModel
    /// Phase 12 Plan 12-01 — observes intents fired from `RishiMenuCommands`
    /// (menu bar + ⌘ shortcuts). `nil` in tests / SwiftUI previews so the
    /// view still renders without the composition root in scope.
    @Environment(\.macCommandRouter) private var commandRouter

    /// Phase 12 — bound to the TabView. `MacCommandIntent.selectTab(_)`
    /// (and `.focusSearch` / `.newConversation`) writes into this so the
    /// menu can switch the visible tab without touching the underlying
    /// `LibraryRootView` / `ConversationsListView`.
    @State private var selectedTab: MacTab = .library

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    /// Non-nil while the reader (or EPUB placeholder) is presented.
    @State private var openTarget: OpenTarget?

    /// Holds the active reader → sync bridge for the lifetime of the open
    /// reader sheet. The bridge polls the VM and forwards position changes
    /// to `SyncEngine.markPositionDirty`. Cleared on dismiss so its task
    /// cancels via `deinit`.
    @State private var pdfSyncBinding: PDFReaderPositionSyncBinding? = nil
    @State private var epubSyncBinding: EPUBReaderPositionSyncBinding? = nil

    /// SYNC-08 — Settings sheet entry point. Presented from the toolbar
    /// gear button below.
    @State private var showSettings = false

    // MARK: - Phase 8 (TTS) state
    //
    // The ReaderTTSBridge is constructed per-reader-sheet by AppDependencies
    // and retained here. Two sheets — the controls and the voice/speed
    // picker — present and dismiss independently.
    @State private var readerTTSBridge: ReaderTTSBridge? = nil
    @State private var showTTSControls = false
    @State private var showTTSPicker = false
    @State private var ttsPickerInitial: TTSSettings = .default

    // MARK: - Phase 9 (Chat) state
    //
    // Conversations tab + chat sheet:
    //   - selectedConversation: row tap from Conversations tab → sheet with
    //     ChatPanelView bound to that conversation
    //   - chatPanelForPresenter: viewmodel resolved asynchronously from
    //     deps.chatPresenter.pendingPresentation (reader chat button or
    //     "Ask about this" selection action)
    @State private var selectedConversation: Conversation? = nil
    @State private var chatPanelForPresenter: ChatPanelViewModel? = nil

    // MARK: - Phase 11 (Onboarding + Billing) state
    //
    // `showOnboarding` is set to !state.hasCompletedOnboarding by the
    // bootstrap task — first-run users see the OnboardingFlowView as a
    // .fullScreenCover. Returning users skip straight to the library.
    @State private var showOnboarding = false
    /// BILL-04 — non-nil while the paywall sheet is presented. The wrapped
    /// String is the feature name passed into `PaywallView`.
    @State private var paywallFeature: PaywallFeature? = nil

    var body: some View {
        Group {
            if let user = currentUser, let deps = deps {
                TabView(selection: $selectedTab) {
                    Tab("Library", systemImage: "books.vertical", value: MacTab.library) {
                        libraryTab(deps: deps, user: user)
                    }
                    Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: MacTab.chats) {
                        conversationsTab(deps: deps, user: user)
                    }
                }
                .sheet(item: $selectedConversation) { convo in
                    let vm = deps.makeChatPanelViewModel(conversation: convo)
                    NavigationStack {
                        ChatPanelHost(
                            presenter: deps.voicePresenter,
                            viewModel: vm,
                            bookId: convo.bookId,
                            initialQuote: nil,
                            onFreeUserTap: {
                                paywallFeature = PaywallFeature(name: "Voice Chat")
                            },
                            entitlementProvider: { [deps] in
                                await deps.entitlementService.snapshot()
                            }
                        )
                    }
                }
                .sheet(
                    item: Binding(
                        get: { deps.chatPresenter.pendingPresentation },
                        set: { newValue in
                            if newValue == nil {
                                deps.chatPresenter.clear()
                                chatPanelForPresenter = nil
                            }
                        }
                    )
                ) { pending in
                    presenterChatSheet(
                        pending: pending,
                        deps: deps,
                        userId: user.id
                    )
                }
            } else {
                signedOutView
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            currentUser = await auth?.currentUser
            // Phase 11 — gate the first-launch onboarding cover on the
            // persisted flag. Refresh entitlement only when the user has
            // already signed in (signed-out users have nothing to fetch).
            if let deps = deps {
                let completed = await deps.onboardingState.hasCompletedOnboarding()
                showOnboarding = !completed
                if currentUser != nil {
                    _ = await deps.entitlementService.refresh()
                }
            }
        }
        // Phase 11 — first-launch onboarding cover. Presented over the
        // signed-in OR signed-out path because we want the welcome screen
        // even before the user has authenticated.
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showOnboarding) {
            if let deps = deps {
                OnboardingHost(
                    dependencies: deps,
                    onCompleted: { showOnboarding = false }
                )
            } else {
                ProgressView()
            }
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            if let deps = deps {
                OnboardingHost(
                    dependencies: deps,
                    onCompleted: { showOnboarding = false }
                )
            } else {
                ProgressView()
            }
        }
        #endif
        // BILL-04 — paywall sheet for free users tapping a Pro feature.
        // Manage-Subscription tap inside `PaywallView` routes through the
        // billing portal service (gated on `ReaderAppEntitlementFlag` by
        // the view itself).
        .sheet(item: $paywallFeature) { feature in
            if let deps = deps {
                PaywallView(
                    feature: feature.name,
                    onSubscribe: {
                        Task { try? await deps.billingPortalService.openPortal() }
                        paywallFeature = nil
                    },
                    onDismiss: { paywallFeature = nil }
                )
            } else {
                ProgressView()
            }
        }
        .onOpenURL { url in
            guard let deps = deps else { return }
            Task {
                _ = await deps.importCoordinator.importBooks([url])
                await libraryViewModel.refresh()
            }
        }
        // Phase 12 Plan 12-01 — drain the Mac command router whenever the
        // menu bar / ⌘-shortcut posts a new intent. We use `.task(id:)` so
        // the closure re-runs on every change to `pendingIntent` (including
        // back-to-back identical intents, because consume() resets to nil).
        .task(id: commandRouter?.pendingIntent) {
            consumePendingMacIntent()
        }
    }

    // MARK: - Mac command intent dispatch (Phase 12 Plan 12-01)

    /// Consumes the latest intent from `commandRouter` and dispatches it to
    /// the matching app surface. NotificationCenter is the seam for surfaces
    /// that live inside SwiftPM packages (RishiLibrary, RishiReader) so
    /// those packages do NOT have to import the rishi app target.
    private func consumePendingMacIntent() {
        guard let router = commandRouter, let intent = router.pendingIntent else { return }
        defer { router.consume() }

        switch intent {
        case .importBook:
            // LibraryRootView observes `RishiCommand.importBook` and toggles
            // its document-picker sheet.
            selectedTab = .library
            NotificationCenter.default.post(name: RishiCommand.importBook, object: nil)

        case .newConversation:
            // Jump to the Chats tab. `ChatPresenterImpl.presentChat` requires
            // a `BookID`, so for an unbound new conversation we let the
            // ConversationsListView's "+" affordance own the actual creation
            // path. This keeps the menu command honest (no half-baked book
            // bindings) while still bringing the user to the right surface.
            selectedTab = .chats

        case .focusSearch:
            selectedTab = .library
            NotificationCenter.default.post(name: RishiCommand.focusSearch, object: nil)

        case .fontIncrease:
            // Per-book typography state lives in the reader VMs. RootView is
            // decoupled from them via NotificationCenter so neither
            // RishiReader nor the host app needs to know about the other.
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
            // Map the Mac/-folder echo enum to the real RishiReader.ReaderTheme
            // and assign to the app-wide reader defaults. Per-book overrides
            // are unaffected (those live in `readerSettingsStore`).
            if let deps {
                deps.readerDefaults.theme = mapReaderTheme(macTheme)
            }

        case .selectTab(let tab):
            selectedTab = tab

        case .pageForward:
            NotificationCenter.default.post(name: RishiCommand.pageForward, object: nil)

        case .pageBackward:
            NotificationCenter.default.post(name: RishiCommand.pageBackward, object: nil)
        }
    }

    /// Maps the Mac/-folder echo theme onto the real `RishiReader.ReaderTheme`.
    /// Keeps the Mac/ files free of a RishiReader dependency.
    private func mapReaderTheme(_ macTheme: MacReaderTheme) -> ReaderTheme {
        switch macTheme {
        case .light: return .light
        case .sepia: return .sepia
        case .dark:  return .dark
        }
    }

    // MARK: - Tabs (Phase 9 wraps Library + Conversations in a TabView)

    @ViewBuilder
    private func libraryTab(deps: AppDependencies, user: User) -> some View {
        LibraryRootView(
            importCoordinator: deps.importCoordinator,
            onOpenBook: { book in openTarget = openTarget(for: book) },
            onShowSettings: { showSettings = true }
        )
        .task(id: user.id) {
            deps.cachedUserId = user.id
            _ = await deps.sampleBookInstaller.installIfNeeded(ownerId: user.id)
            _ = await deps.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
            await libraryViewModel.refresh()
        }
        #if canImport(UIKit)
        .fullScreenCover(item: $openTarget) { target in
            destinationView(for: target, deps: deps, userId: user.id)
        }
        #else
        .sheet(item: $openTarget) { target in
            destinationView(for: target, deps: deps, userId: user.id)
        }
        #endif
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                dependencies: deps,
                user: user,
                onSignedOut: { currentUser = nil }
            )
        }
    }

    @ViewBuilder
    private func conversationsTab(deps: AppDependencies, user: User) -> some View {
        NavigationStack {
            ConversationsListView(
                viewModel: deps.makeConversationsListViewModel(),
                userId: user.id,
                onSelect: { convo in selectedConversation = convo }
            )
        }
    }

    /// Resolves the chat-panel viewmodel asynchronously and presents the
    /// ``ChatPanelView``. Used for the presenter-driven flow (reader chat
    /// button + "Ask about this" selection action).
    @ViewBuilder
    private func presenterChatSheet(
        pending: ChatPresenterImpl.Pending,
        deps: AppDependencies,
        userId: UserID
    ) -> some View {
        Group {
            if let vm = chatPanelForPresenter {
                NavigationStack {
                    ChatPanelHost(
                        presenter: deps.voicePresenter,
                        viewModel: vm,
                        bookId: pending.bookId,
                        initialQuote: pending.initialQuote,
                        onFreeUserTap: {
                            paywallFeature = PaywallFeature(name: "Voice Chat")
                        },
                        entitlementProvider: { [deps] in
                            await deps.entitlementService.snapshot()
                        }
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: pending.id) {
            chatPanelForPresenter = await deps.makeChatPanelViewModel(
                userId: userId,
                bookId: pending.bookId
            )
        }
    }

    // MARK: - Navigation destinations

    private func openTarget(for book: Book) -> OpenTarget {
        switch book.formatType {
        case .pdf:            return .pdf(book)
        case .epub:           return .epub(book)
        case .mobi, .azw3:    return .unsupportedFormat(book)
        }
    }

    @ViewBuilder
    private func destinationView(for target: OpenTarget,
                                 deps: AppDependencies,
                                 userId: UserID) -> some View {
        switch target {
        case .pdf(let book):
            let pdfVM = PDFReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
            PDFReaderScreen(
                viewModel: pdfVM,
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    Task {
                        // BILL-04 — gate Pro features on entitlement.
                        let level = await deps.entitlementService.snapshot()
                        guard level == .pro else {
                            paywallFeature = PaywallFeature(name: "Read Aloud")
                            return
                        }
                        await startPDFReadAloud(vm: pdfVM, deps: deps, userId: userId)
                    }
                } : nil,
                chatPresenter: deps.chatPresenter
            )
            // SYNC-03 wiring: install a sync bridge for the lifetime of the
            // reader sheet. The binding cancels its poll task on deinit.
            .task {
                pdfSyncBinding = PDFReaderPositionSyncBinding(
                    viewModel: pdfVM,
                    syncEngine: deps.syncEngine
                )
            }
            .onDisappear {
                pdfSyncBinding = nil
                Task { await stopReadAloud() }
            }
            .sheet(isPresented: $showTTSControls) {
                if let bridge = readerTTSBridge {
                    ReadAloudControlsView(
                        state: deps.ttsState,
                        onPlayPause: {
                            Task {
                                if deps.ttsState.status == .playing {
                                    await bridge.pause()
                                } else {
                                    await bridge.resume()
                                }
                            }
                        },
                        onStop: {
                            Task { await stopReadAloud() }
                        },
                        onOpenPicker: {
                            showTTSPicker = true
                        }
                    )
                    .presentationDetents([.height(180), .medium])
                }
            }
            .sheet(isPresented: $showTTSPicker) {
                VoiceAndSpeedPicker(
                    initial: ttsPickerInitial,
                    userId: userId,
                    store: deps.ttsSettingsStore,
                    onDismiss: { settings in
                        ttsPickerInitial = settings
                        showTTSPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        case .epub(let book):
            let epubVM = EPUBReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
            EPUBReaderScreen(
                viewModel: epubVM,
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    Task {
                        // BILL-04 — gate Pro features on entitlement.
                        let level = await deps.entitlementService.snapshot()
                        guard level == .pro else {
                            paywallFeature = PaywallFeature(name: "Read Aloud")
                            return
                        }
                        await startEPUBReadAloud(vm: epubVM, deps: deps, userId: userId)
                    }
                } : nil,
                chatPresenter: deps.chatPresenter
            )
            .task {
                epubSyncBinding = EPUBReaderPositionSyncBinding(
                    viewModel: epubVM,
                    syncEngine: deps.syncEngine
                )
            }
            .onDisappear {
                epubSyncBinding = nil
                Task { await stopReadAloud() }
            }
            .sheet(isPresented: $showTTSControls) {
                if let bridge = readerTTSBridge {
                    ReadAloudControlsView(
                        state: deps.ttsState,
                        onPlayPause: {
                            Task {
                                if deps.ttsState.status == .playing {
                                    await bridge.pause()
                                } else {
                                    await bridge.resume()
                                }
                            }
                        },
                        onStop: {
                            Task { await stopReadAloud() }
                        },
                        onOpenPicker: {
                            showTTSPicker = true
                        }
                    )
                    .presentationDetents([.height(180), .medium])
                }
            }
            .sheet(isPresented: $showTTSPicker) {
                VoiceAndSpeedPicker(
                    initial: ttsPickerInitial,
                    userId: userId,
                    store: deps.ttsSettingsStore,
                    onDismiss: { settings in
                        ttsPickerInitial = settings
                        showTTSPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        case .unsupportedFormat(let book):
            EpubPlaceholderView(book: book) {
                openTarget = nil
            }
        }
    }

    // MARK: - Read Aloud (Phase 8)

    private func startPDFReadAloud(
        vm: PDFReaderViewModel,
        deps: AppDependencies,
        userId: UserID
    ) async {
        #if canImport(PDFKit)
        guard let doc = vm.document else { return }
        let sentences = vm.sentencesForReadAloud(
            document: doc,
            currentPageIndex: vm.pageIndex
        )
        await startReadAloud(
            sentences: sentences,
            deps: deps,
            userId: userId,
            onPassageChange: { index in vm.currentReadAloudPassageIndex = index }
        )
        #endif
    }

    private func startEPUBReadAloud(
        vm: EPUBReaderViewModel,
        deps: AppDependencies,
        userId: UserID
    ) async {
        let sentences = await vm.sentencesForReadAloud()
        await startReadAloud(
            sentences: sentences,
            deps: deps,
            userId: userId,
            onPassageChange: { index in vm.currentReadAloudPassageIndex = index }
        )
    }

    private func startReadAloud(
        sentences: [String],
        deps: AppDependencies,
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void
    ) async {
        guard !sentences.isEmpty else { return }
        // Tear down any existing bridge before starting a new session.
        if let existing = readerTTSBridge {
            await existing.stop()
        }
        let bridge = deps.makeReaderTTSBridge(
            userId: userId,
            onPassageChange: onPassageChange
        )
        readerTTSBridge = bridge
        ttsPickerInitial = await deps.ttsSettingsStore.load(userId: userId)
        showTTSControls = true
        await bridge.start(sentences: sentences)
    }

    private func stopReadAloud() async {
        if let bridge = readerTTSBridge {
            await bridge.stop()
        }
        readerTTSBridge = nil
        showTTSControls = false
        showTTSPicker = false
    }

    private func pdfFileURL(for book: Book) -> URL {
        // `BookFileStorage` is an actor, but its file-URL computation is a
        // pure path concat that only reads the configured root URL. We
        // recompute the same thing here using the Documents directory so
        // we don't need to await across the actor boundary at view-build
        // time.
        let documentsURL = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return documentsURL.appendingPathComponent(book.fileURL)
    }

    @ViewBuilder private var signedOutView: some View {
        #if DEBUG
        NavigationStack { DebugAuthView() }
        #else
        VStack {
            Text("Sign in to Rishi to access your library")
                .font(.title2)
                .padding()
        }
        #endif
    }
}

/// BILL-04 — Identifiable wrapper so `.sheet(item:)` can drive a paywall
/// keyed by the feature name. String isn't Identifiable in stdlib; using a
/// dedicated struct keeps the @State binding straightforward.
private struct PaywallFeature: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// Hashable + Identifiable nav target so `fullScreenCover(item:)` can
/// pick the correct destination based on book format.
private enum OpenTarget: Hashable, Identifiable {
    case pdf(Book)
    case epub(Book)
    case unsupportedFormat(Book)

    var id: BookID {
        switch self {
        case .pdf(let book), .epub(let book), .unsupportedFormat(let book):
            return book.id
        }
    }
}

/// Catches `.mobi` / `.azw3` taps — those formats need a converter step
/// that isn't on the v1 milestone. Shipped here so the library never
/// silently no-ops when the user taps an unsupported book.
private struct EpubPlaceholderView: View {
    let book: Book
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                Text(book.title)
                    .font(.title3)
                Text("MOBI / AZW3 aren't supported yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

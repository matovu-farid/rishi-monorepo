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
import RishiUIKit
#if canImport(PDFKit)
import PDFKit
#endif

/// Floating-card surface for the read-aloud controls. iOS 26 gets a native
/// Liquid Glass effect; iOS 18 falls back to `.regularMaterial`. Both clip to
/// the same rounded rectangle so the card shape is identical across versions.
private struct GlassCardBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
        }
    }
}

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps
    /// Phase 19 plan 19-01 — LibraryViewModel is now part of the
    /// `BootstrappedServices` graph, reached via `deps.libraryViewModel`.
    /// We no longer pull it from `@Environment(LibraryViewModel.self)`
    /// because that environment slot would be nil until bootstrap
    /// completes; routing through `deps` keeps the lookup uniform with
    /// the rest of the services accessors.
    private var libraryViewModel: LibraryViewModel? { deps?.services?.libraryViewModel }
    /// Phase 12 Plan 12-01 — observes intents fired from `RishiMenuCommands`
    /// (menu bar + ⌘ shortcuts). `nil` in tests / SwiftUI previews so the
    /// view still renders without the composition root in scope.
    @Environment(\.macCommandRouter) private var commandRouter

    // MARK: - Phase 12 Plan 12-02 — @SceneStorage cells (MAC-05)
    //
    // SwiftUI restores `@SceneStorage` per scene-session, so closing the
    // app with a book open and relaunching reopens the same reader cover
    // on the same tab. We use two cells so each value is individually
    // restorable:
    //   - selectedTabRaw → JSON-encoded `RishiSceneState` snapshot (the
    //     full struct, future-proofed for additional fields).
    //   - openBookIdRaw  → bare UUID string of the currently-open book,
    //     or "" when no reader cover is on screen. Kept in its own cell
    //     so a corrupted tab cell does not also wipe the reader pointer.
    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw: String = ""
    @SceneStorage(RishiSceneState.openBookIdKey)  private var openBookIdRaw: String = ""
    /// Guards the scene-restoration `.task` so we don't keep re-running
    /// the bookStore lookup on every body refresh.
    @State private var sceneRestored = false

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false
    /// Phase 21 perf — gate the signed-in/signed-out branch on the FIRST
    /// completion of the auth probe. Previously `realBodyContent` rendered
    /// `signedOutView` whenever `currentUser` was nil, which was true for
    /// the entire window between view-first-appear and the `.task` body's
    /// `await auth?.currentUser` returning. On a cold launch with a valid
    /// keychain session that window is hundreds of ms (actor hop + keychain
    /// SecItemCopyMatching + observability bookkeeping), so the user saw
    /// the signed-out screen flash before being swapped to the library.
    /// `authProbeComplete` defaults to false; the bootstrap `.task` sets it
    /// to true exactly once after the probe resolves, whether or not a
    /// session existed.
    @State private var authProbeComplete = false

    /// Phase 20 perf — transient cache of already-resolved `Book` values
    /// keyed by `BookID`, populated on every push that originated from a
    /// site that had the full `Book` in hand (library tap, Mac intent,
    /// legacy scene-restore B). `NavigationLazyBook` consumes a hint via
    /// `initialValue:` so the reader paints first frame without a fresh
    /// `bookStore.book(_:)` round-trip (which previously caused a
    /// `ProgressView()` flash between tap and first paint).
    ///
    /// Intentionally NOT persisted — cold-launch scene restoration leaves
    /// this empty and `NavigationLazyBook` falls back to its existing
    /// `.task { bookStore.book(_:) }` DB read.
    @State private var bookHints: [BookID: Book] = [:]

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
    // Owned by ReadAloudController, created once user + services are available.
    // The controller holds the optional ReaderTTSBridge, paragraph list,
    // showControls, showPicker, pickerInitial, and currentParagraph.
    @State private var readAloud: ReadAloudController? = nil

    /// reader-tts-xml-and-loading fix — reader view-models MUST survive
    /// RootView body recomputes. Previously `pdfReaderDestination` /
    /// `epubReaderDestination` constructed the VM as a plain `let` local in
    /// the @ViewBuilder body, so any RootView @State mutation (e.g. tapping
    /// Read Aloud flips `showTTSControls`/`readerTTSBridge`) rebuilt a fresh
    /// `.idle` VM. That re-showed the "Opening {book}" cold-open overlay
    /// (stuck), tore the reader down mid-playback, and left the TTS controls
    /// sheet bound to a discarded VM (blank white sheet). This @State-held
    /// cache memoizes one VM per book id so recomputes reuse the loaded
    /// instance.
    @State private var readerVMCache = ReaderViewModelCache()

    // MARK: - Phase 9 (Chat) state
    //
    // Conversations tab + chat sheet:
    //   - selectedConversation: row tap from Conversations tab → sheet with
    //     ChatPanelView bound to that conversation
    //   - chatPresenter.pendingPresentation: presenter-driven flow (reader
    //     chat button / "Ask about this") — VM is now owned by
    //     ChatPanelHostView, not RootView state.
    @State private var selectedConversation: Conversation? = nil

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
        // Phase 19 plan 19-01 (F-P0-01) — gate the real UI on bootstrap
        // completion. `deps.services` flips non-nil after the off-main
        // factory finishes. SwiftUI re-evaluates `body` because `deps`
        // is `@State`-held and `services` is a `private(set) var` on a
        // `@MainActor` class. Until then we show a ProgressView so first
        // frame paints immediately instead of the user staring at a
        // black/launchscreen-frozen window for hundreds of ms.
        if let deps, deps.services != nil {
            realBody(deps: deps)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading Rishi")
        }
    }

    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {
        // Phase 19 plan 19-01 — re-inject object-typed environments that
        // used to live on the `WindowGroup` root. They can only be
        // installed once `deps.services` is non-nil, which the outer
        // `body` guard guarantees here. `LibraryRootView` reads
        // `@Environment(LibraryViewModel.self)`, and `ManageSubscriptionRow`
        // (presented from `SettingsSheet`) reads
        // `@Environment(ManageSubscriptionPresenter.self)`.
        realBodyContent(deps: deps)
            .environment(deps.libraryViewModel)
            .environment(deps.manageSubscriptionPresenter)
    }

    @ViewBuilder
    private func realBodyContent(deps: AppDependencies) -> some View {
        Group {
            if !authProbeComplete {
                // Phase 21 perf — first paint while the keychain probe runs.
                // Painting `signedOutView` here would flash sign-in UI for
                // users who ARE signed in (the `.task` below hasn't resolved
                // yet on the first body evaluation). A blank background
                // matches the launch screen color so the transition into the
                // library / signed-out branch is seamless.
                #if canImport(UIKit)
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #else
                Color.clear
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #endif
            } else if let user = currentUser {
                // Single home on every device: no bottom tab bar (iPhone) and
                // no sidebar (iPad/Mac). Library is the root; its toolbar Chats
                // button pushes the conversations list onto the SAME
                // NavigationStack the reader uses (libraryPath), so the back
                // chevron + edge-swipe work everywhere. Menu-bar / ⌘ intents
                // drive the same stack (see consumePendingMacIntent).
                libraryTab(
                    deps: deps,
                    user: user,
                    onShowChats: { router.showConversations() }
                )
                .sheet(item: $selectedConversation) { convo in
                    if let services = deps.services {
                        ConversationChatHost(
                            conversation: convo,
                            services: services,
                            onFreeUserTap: {
                                paywallFeature = PaywallFeature(name: "Voice Chat")
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
                            }
                        }
                    )
                ) { pending in
                    if let services = deps.services {
                        ChatPanelHostView(
                            pending: pending,
                            userId: user.id,
                            services: services,
                            onFreeUserTap: {
                                paywallFeature = PaywallFeature(name: "Voice Chat")
                            }
                        )
                    }
                }
            } else {
                signedOutView
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            // Phase 21 perf — order matters: probe the keychain FIRST and
            // flip `authProbeComplete` so the body swaps from the blank
            // loading background straight into the library (or sign-in)
            // before any of the secondary bootstrap awaits run. Entitlement
            // refresh + onboarding flag read both touch the worker / disk
            // and would otherwise extend the loading-background window for
            // signed-in users who don't need either result before first paint.
            let probedUser = await auth?.currentUser
            currentUser = probedUser
            authProbeComplete = true
            // Phase 11 — gate the first-launch onboarding cover on the
            // persisted flag. Refresh entitlement only when the user has
            // already signed in (signed-out users have nothing to fetch).
            // Phase 19 plan 19-01 — deps is now non-optional inside
            // realBody (services already verified).
            //
            // Phase 21 perf — `hasCompletedOnboarding()` (UserDefaults
            // read on a MainActor-isolated store) and
            // `entitlementService.refresh()` (worker round-trip on an
            // actor) are independent of each other. Fan them out with
            // `async let` so the network probe overlaps with the local
            // onboarding flag read instead of stalling behind it.
            if probedUser != nil {
                async let completedAsync = deps.onboardingState.hasCompletedOnboarding()
                async let entitlementAsync = deps.entitlementService.refresh()
                let (completed, _) = await (completedAsync, entitlementAsync)
                showOnboarding = !completed
            } else {
                let completed = await deps.onboardingState.hasCompletedOnboarding()
                showOnboarding = !completed
            }
        }
        // Phase 11 — first-launch onboarding cover. Presented over the
        // signed-in OR signed-out path because we want the welcome screen
        // even before the user has authenticated.
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingHost(
                dependencies: deps,
                onCompleted: { showOnboarding = false }
            )
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            OnboardingHost(
                dependencies: deps,
                onCompleted: { showOnboarding = false }
            )
        }
        #endif
        // BILL-04 — paywall sheet for free users tapping a Pro feature.
        // PaywallHost owns the PaywallViewModel for the lifetime of the sheet,
        // routing through the live Wave-3 path (tier selector, subscribe,
        // restore, manage, 3.1.2 disclosure). deps.services is non-nil here
        // because realBody is only entered after the outer body guard passes.
        .sheet(item: $paywallFeature) { feature in
            if let services = deps.services {
                PaywallHost(
                    feature: feature,
                    services: services,
                    onDismiss: { paywallFeature = nil }
                )
            }
        }
        // Phase 12 Plan 12-03 — every inbound URL (custom `rishi://` scheme
        // OR `https://rishi.fidexa.org/...` Universal Link) is funneled
        // through `AppRouter`, which calls `DeepLinkRouter` internally.
        // Legacy file:// import taps from Files / share-sheet fall through
        // to the `.unknown` branch so book imports keep working.
        .onOpenURL { url in
            // Wire the side-effect callbacks before dispatching so the
            // router can populate bookHints and selectedConversation which
            // are still owned by RootView.
            router.onBookResolved = { book in
                bookHints[book.id] = book
            }
            router.onConversationResolved = { convo in
                selectedConversation = convo
            }
            router.onFileURL = { fileURL in
                Task {
                    _ = await deps.importCoordinator.importBooks([fileURL])
                    await libraryViewModel?.refresh()
                }
            }
            router.handle(url: url, deps: deps)
        }
        // Phase 12 Plan 12-01 — drain the Mac command router whenever the
        // menu bar / ⌘-shortcut posts a new intent. We use `.task(id:)` so
        // the closure re-runs on every change to `pendingIntent` (including
        // back-to-back identical intents, because consume() resets to nil).
        .task(id: commandRouter?.pendingIntent) {
            consumePendingMacIntent()
        }
        // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader
        // cover from `@SceneStorage` on first appearance. Guarded by
        // `sceneRestored` so a re-render of the body does not retrigger
        // the bookStore lookup. Wire the bookHints callback before restoring
        // so the legacy-B path can populate the hint cache.
        .task {
            guard !sceneRestored else { return }
            sceneRestored = true
            router.onBookResolved = { book in
                bookHints[book.id] = book
            }
            await router.applyRestored(
                tabRaw: selectedTabRaw,
                openBookIdRaw: openBookIdRaw,
                deps: deps
            )
        }
        // Persist the latest scene state on every visible change. Re-encode
        // the whole struct on each delta so the storage cell always holds an
        // up-to-date snapshot.
        .onChange(of: router.path) { _, _ in
            let cells = router.persistCells()
            selectedTabRaw = cells.tabRaw
            openBookIdRaw  = cells.openBookIdRaw
        }
    }

    // MARK: - Mac command intent dispatch (Phase 12 Plan 12-01)

    /// Consumes the latest intent from `commandRouter` and dispatches it to
    /// the matching app surface. NotificationCenter is the seam for surfaces
    /// that live inside SwiftPM packages (RishiLibrary, RishiReader) so
    /// those packages do NOT have to import the rishi app target.
    private func consumePendingMacIntent() {
        guard let cmdRouter = commandRouter, let intent = cmdRouter.pendingIntent else { return }
        defer { cmdRouter.consume() }

        switch intent {
        case .importBook:
            // LibraryRootView observes `RishiCommand.importBook` and toggles
            // its document-picker sheet. Bring the Library root to front first.
            router.showLibraryRoot()
            NotificationCenter.default.post(name: RishiCommand.importBook, object: nil)

        case .newConversation:
            // Show the conversations list. `ChatPresenterImpl.presentChat`
            // requires a `BookID`, so for an unbound new conversation we let the
            // ConversationsListView's "+" affordance own the actual creation
            // path. This keeps the menu command honest (no half-baked book
            // bindings) while still bringing the user to the right surface.
            router.showConversations()

        case .focusSearch:
            router.showLibraryRoot()
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
            // No tab/sidebar anymore — map the surface selection onto the
            // Library NavigationStack.
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
    private func libraryTab(
        deps: AppDependencies,
        user: User,
        onShowChats: (() -> Void)? = nil
    ) -> some View {
        // Phase 18 Plan 18-01 (F-P0-01) — host-owned NavigationStack.
        // LibraryRootView's internal NavigationStack is bypassed via the
        // host-path initializer so the reader can push onto THIS stack and
        // the system back chevron + edge-swipe-from-left are always
        // available. Nested NavigationStacks crash iPad split-view.
        // Use @Bindable to get a two-way Binding to the @Observable router's
        // `path` property for the NavigationStack (Swift 6 Observation pattern).
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
                path: bindableRouter.path,
                importCoordinator: deps.importCoordinator,
                onOpenBook: { book in
                    bookHints[book.id] = book
                    router.path.append(ReaderRoute.route(for: book))
                },
                onShowSettings: { showSettings = true },
                onShowChats: onShowChats,
                onImported: { outcomes in
                    // Phase 21 follow-up — auto-open the reader when the
                    // user imported exactly ONE book successfully. Multi-
                    // book batches stay on the library (we don't push N
                    // readers). Mirrors the `onOpenBook` path so the
                    // NavigationLazyBook hint mechanism (c50e91169) kicks
                    // in for instant first paint.
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first else { return }
                    bookHints[book.id] = book
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                destinationView(for: route, deps: deps, userId: user.id)
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                conversationsDestination(deps: deps, user: user)
            }
            .task(id: user.id) {
                deps.cachedUserId = user.id
                // Phase 21 perf — sample installers are independent of each
                // other (different bundle resources, different DB rows). Fan
                // them out with `async let` so the bundle lookup + file copy
                // overlap; the joint await at `_ = await (a, b)` resumes once
                // both finish. `refresh()` STILL has to wait because it reads
                // the books table that the installers may have just written.
                async let sample = deps.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                async let reader = deps.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
                _ = await (sample, reader)
                await libraryViewModel?.refresh()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(
                dependencies: deps,
                user: user,
                onSignedOut: { currentUser = nil }
            )
        }
    }

    /// Conversations list pushed onto the Library NavigationStack. The host
    /// stack (libraryPath) provides the chrome / back chevron, so this renders
    /// the list WITHOUT wrapping it in its own NavigationStack.
    @ViewBuilder
    private func conversationsDestination(deps: AppDependencies, user: User) -> some View {
        if let services = deps.services {
            ConversationsListHost(
                services: services,
                userId: user.id,
                onSelect: { convo in selectedConversation = convo }
            )
        }
    }

    // MARK: - Navigation destinations

    /// Phase 18 Plan 18-01 — `NavigationStack`'s `.navigationDestination`
    /// hands us a `ReaderRoute` (BookID + format). We resolve the full
    /// `Book` lazily inside `NavigationLazyBook` so the push payload stays
    /// `Codable` for scene restoration.
    @ViewBuilder
    private func destinationView(for route: ReaderRoute,
                                 deps: AppDependencies,
                                 userId: UserID) -> some View {
        switch route {
        case .pdf(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], deps: deps) { book in
                pdfReaderDestination(book: book, deps: deps, userId: userId)
            }
        case .epub(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], deps: deps) { book in
                epubReaderDestination(book: book, deps: deps, userId: userId)
            }
        case .unsupportedFormat(let bookId):
            NavigationLazyBook(bookId: bookId, hint: bookHints[bookId], deps: deps) { book in
                EpubPlaceholderView(book: book) {
                    if !router.path.isEmpty { router.path.removeLast() }
                }
            }
        }
    }

    @ViewBuilder
    private func pdfReaderDestination(book: Book,
                                      deps: AppDependencies,
                                      userId: UserID) -> some View {
        let pdfVM = readerVMCache.pdf(for: book.id) {
            PDFReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
        }
        PDFReaderScreen(
                viewModel: pdfVM,
                readerSettingsStore: deps.readerSettingsStore,
                highlightStore: deps.highlightStore,
                onReadAloud: FeatureFlags.readAloud ? {
                    // KEEP: outer Task only chains MainActor awaits
                    // (entitlementService is an actor, ReadAloudController.startPDF
                    // is @MainActor); the heavy PDF text extraction is
                    // detached inside startPDF itself.
                    Task {
                        // BILL-04 — gate Pro features on entitlement.
                        let level = await deps.entitlementService.snapshot()
                        guard level == .pro else {
                            paywallFeature = PaywallFeature(name: "Read Aloud")
                            return
                        }
                        if readAloud == nil {
                            readAloud = ReadAloudController(
                                ttsEngine: deps.ttsEngine,
                                ttsState: deps.ttsState,
                                ttsSettingsStore: deps.ttsSettingsStore,
                                ttsPrewarmer: deps.ttsPrewarmer,
                                userId: userId
                            )
                        }
                        await readAloud?.startPDF(vm: pdfVM)
                    }
                } : nil,
                chatPresenter: deps.chatPresenter,
                readAloudParagraph: readAloud?.currentParagraph
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
                // reader-tts-xml-and-loading fix — drop the cached VM so a
                // future reopen re-reads the persisted position fresh.
                readerVMCache.drop(book.id)
                // KEEP: stop cancels the @MainActor bridge; UI-only.
                Task { await readAloud?.stop() }
            }
            .overlay(alignment: .bottom) {
                readAloudControlsOverlay(deps: deps)
            }
            .sheet(isPresented: Binding(
                get: { readAloud?.showPicker ?? false },
                set: { if !$0 { readAloud?.showPicker = false } }
            )) {
                if let ra = readAloud {
                    VoiceAndSpeedPicker(
                        initial: ra.pickerInitial,
                        userId: userId,
                        store: deps.ttsSettingsStore,
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
                                       deps: AppDependencies,
                                       userId: UserID) -> some View {
        let epubVM = readerVMCache.epub(for: book.id) {
            EPUBReaderViewModel(
                book: book,
                userId: userId,
                documentURL: pdfFileURL(for: book),
                positionStore: deps.positionStore
            )
        }
        EPUBReaderScreen(
            viewModel: epubVM,
            readerSettingsStore: deps.readerSettingsStore,
            highlightStore: deps.highlightStore,
            onReadAloud: FeatureFlags.readAloud ? {
                // KEEP: outer Task only chains MainActor awaits; the heavy
                // EPUB resource read + HTML strip is detached inside
                // ReadAloudController.startEPUB (paragraphsForReadAloud) per F-P0-06.
                Task {
                    // BILL-04 — gate Pro features on entitlement. The UI-test
                    // bypass skips the gate (the live worker downgrades the fake
                    // user to .free even with the seeded .pro cache).
                    let level = await deps.entitlementService.snapshot()
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
                            ttsEngine: deps.ttsEngine,
                            ttsState: deps.ttsState,
                            ttsSettingsStore: deps.ttsSettingsStore,
                            ttsPrewarmer: deps.ttsPrewarmer,
                            userId: userId
                        )
                    }
                    await readAloud?.startEPUB(vm: epubVM)
                }
            } : nil,
            chatPresenter: deps.chatPresenter,
            readAloudParagraph: readAloud?.currentParagraph
        )
        .task {
            // A manual page-turn / chapter switch leaves the narrated page, so
            // stop stale read-aloud. The coordinator tags auto-follow
            // navigations as programmatic, so this fires only on real user
            // navigation and never feeds back into the view-follows-audio path.
            epubVM.onUserNavigation = { _ in
                Task { await readAloud?.stop() }
            }
            epubSyncBinding = EPUBReaderPositionSyncBinding(
                viewModel: epubVM,
                syncEngine: deps.syncEngine
            )
        }
        .onDisappear {
            epubSyncBinding = nil
            // reader-tts-xml-and-loading fix — drop the cached VM so a future
            // reopen re-reads the persisted position fresh.
            readerVMCache.drop(book.id)
            // KEEP: stop cancels the @MainActor bridge.
            Task { await readAloud?.stop() }
        }
        .overlay(alignment: .bottom) {
            readAloudControlsOverlay(deps: deps)
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: deps.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Read Aloud (Phase 8)

    /// Floating Read Aloud controls rendered as a bottom overlay on the book
    /// screen (replacing the prior `.sheet`), so the page — and its inline
    /// passage highlight — stays visible while playback runs. Shows nothing
    /// until a session starts (`showTTSControls` + a live bridge). Styled as a
    /// floating card: elevated material background, rounded corners, safe-area
    /// aware, animated in/out.
    @ViewBuilder
    private func readAloudControlsOverlay(deps: AppDependencies) -> some View {
        if let ra = readAloud, ra.showControls, let bridge = ra.bridge {
            ReadAloudControlsView(
                state: deps.ttsState,
                onPlayPause: {
                    // KEEP: pause/resume routes through the TTS engine actor;
                    // outer Task only chains the await — no main-bound IO.
                    Task {
                        if deps.ttsState.status == .playing {
                            await bridge.pause()
                        } else {
                            await bridge.resume()
                        }
                    }
                },
                onStop: {
                    // KEEP: stop cancels the @MainActor bridge.
                    Task { await ra.stop() }
                },
                onOpenPicker: {
                    ra.showPicker = true
                },
                onPreviousParagraph: {
                    // KEEP: previous() routes through the @MainActor bridge;
                    // outer Task only chains the await.
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
        // Quick-SXI: replaced Phase-3 debug stub. SignedOutView pulls
        // (any AuthService)? from @Environment(\.rishiAuthService) — same
        // wire rishiApp already injects in `.environment(\.rishiAuthService,
        // deps.authServiceForEnvironment)`. Both DEBUG and Release render
        // the same surface; DebugAuthView remains on disk under #if DEBUG
        // but is no longer reachable from this signed-out path.
        //
        // `onSignedIn`: SignedOutView's VM fires this exactly once after
        // the SIWA worker round-trip succeeds. We flip `currentUser` on
        // the main actor so RootView's body branches into the signed-in
        // tree on the next render, unmounting SignedOutView and
        // preventing the duplicate `auth.siwa.started` /
        // `/api/auth/sign-in/social` 403 that the previous fire-and-
        // forget bootstrap pattern allowed (see
        // `.planning/debug/resolved/siwa-double-fire-403.md`).
        //
        // We also refresh the entitlement snapshot here for parity with
        // the bootstrap branch in the outer `.task` so a freshly signed-
        // in user immediately has Pro state available.
        SignedOutView(onSignedIn: { user in
            currentUser = user
            if let deps {
                // KEEP: fire-and-forget actor hop — entitlementService is an
                // actor and refresh() awaits the worker on its own executor;
                // the outer Task only chains the await.
                Task { _ = await deps.entitlementService.refresh() }
            }
        })
    }
}

/// BILL-04 — Identifiable wrapper so `.sheet(item:)` can drive a paywall
/// keyed by the feature name. String isn't Identifiable in stdlib; using a
/// dedicated struct keeps the @State binding straightforward.
/// Internal (not private) so `PaywallHost` (same module) can reference it.
struct PaywallFeature: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// reader-tts-xml-and-loading fix — memoizes reader view-models per book id
/// across RootView body recomputes.
///
/// The reader VMs (`PDFReaderViewModel` / `EPUBReaderViewModel`) carry the
/// loaded document/publication and the `.loaded` `loadingState`. They were
/// previously constructed as plain `let` locals inside the `@ViewBuilder`
/// destination functions, so every RootView body recompute (e.g. tapping
/// Read Aloud, which mutates `showTTSControls` / `readerTTSBridge` @State)
/// minted a fresh `.idle` VM and handed it to the structurally-identical
/// reader screen — re-showing the stuck "Opening {book}" cold-open overlay
/// and detaching the TTS controls sheet from the live VM.
///
/// This cache is held in RootView `@State` (stable reference identity), so
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

/// Phase 18 Plan 18-01 — async-resolve a `Book` from a `BookID` for use
/// inside a `NavigationStack` destination. The path itself only carries
/// `ReaderRoute` (Codable + BookID) so scene restoration stays primitive.
/// This helper performs the `deps.bookStore.book(_:)` lookup on appear,
/// rendering a `ProgressView` until the book resolves.
private struct NavigationLazyBook<Content: View>: View {
    let bookId: BookID
    let deps: AppDependencies
    let content: (Book) -> Content

    @State private var book: Book?

    /// Phase 20 perf — accept an optional `hint` so call sites that
    /// already have the resolved `Book` (library tap, Mac intent, legacy
    /// scene-restore B) can seed `@State` and skip the
    /// `bookStore.book(_:)` round-trip entirely. The fallback DB read
    /// still runs whenever the hint is nil (cold launch scene restore
    /// path), so existing behaviour is preserved.
    init(bookId: BookID,
         hint: Book? = nil,
         deps: AppDependencies,
         @ViewBuilder content: @escaping (Book) -> Content) {
        self.bookId = bookId
        self.deps = deps
        self.content = content
        self._book = State(initialValue: hint)
    }

    var body: some View {
        Group {
            if let book {
                content(book)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: bookId) {
            if book == nil {
                book = try? await deps.bookStore.book(bookId)
            }
        }
    }
}

#Preview("Signed in") {
    PreviewPlaceholder(
        title: "Library",
        subtitle: "Signed-in users see the library, chats, and reader.",
        variant: "Signed in"
    )
}

#Preview("Signed out") {
    PreviewPlaceholder(
        title: "Sign in to Rishi",
        subtitle: "Signed-out users see the onboarding or debug auth surface.",
        variant: "Signed out"
    )
}

#Preview("Loading") {
    PreviewPlaceholder(
        title: "Loading",
        subtitle: "Bootstrap task is resolving the current user.",
        variant: "Loading"
    )
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

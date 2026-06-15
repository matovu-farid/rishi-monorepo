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
import RishiAuth
import RishiBilling
import RishiChat
import RishiLibrary
import RishiOnboarding
import RishiReader
import RishiSettings
import RishiUIKit

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

    /// Shell presentation state: conversation sheet, paywall sheet, settings
    /// sheet, and transient book-hint cache. Extracted into a viewModel so
    /// these concerns are unit-testable independently of the view.
    @State private var model = SignedInViewModel()

    /// Guards the scene-restoration .task so we don't re-run it on every
    /// body refresh. (Moved from RootView because it is signed-in-only logic.)
    @State private var sceneRestored = false

    // MARK: - Body

    var body: some View {
        @Bindable var model = model
        libraryTab(
            services: services,
            user: user,
            onShowChats: { router.showConversations() }
        )
        .environment(libraryVM)
        .sheet(item: $model.selectedConversation) { convo in
            ConversationChatHost(
                conversation: convo,
                services: services,
                onFreeUserTap: {
                    model.requestPaywall("Voice Chat")
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
                    model.requestPaywall("Voice Chat")
                }
            )
        }
        // BILL-04 — paywall sheet.
        .sheet(item: $model.paywallFeature) { feature in
            PaywallHost(
                feature: feature,
                services: services,
                onDismiss: { model.dismissPaywall() }
            )
        }
        // Phase 12 Plan 12-03 — deep-link dispatch via AppRouter.
        .onOpenURL { url in
            router.onBookResolved = { book in
                model.hint(book)
            }
            router.onConversationResolved = { convo in
                model.present(conversation: convo)
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
                model.hint(book)
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
        @Bindable var model = model
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
                path: bindableRouter.path,
                importCoordinator: services.importCoordinator,
                onOpenBook: { book in
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                },
                onShowSettings: { model.requestSettings() },
                onShowChats: onShowChats,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first else { return }
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(
                    route: route,
                    services: services,
                    userId: user.id,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { model.requestPaywall($0) }
                )
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
        .sheet(isPresented: $model.showSettings) {
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
            onSelect: { convo in model.present(conversation: convo) }
        )
    }

}

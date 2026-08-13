










import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct SignedInContentDependencies {
    let library: LibraryTabDependencies
    let chatService: any ChatService
    let messageStore: any MessageStore
    let voicePresenter: VoiceSessionPresenter
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let dataUseConsentStore: any DataUseConsentStore
    let deleteAccount: @Sendable (UUID) async throws -> Void

    @MainActor
    static func make(
        services: BootstrappedServices,
        onSignedOut: @escaping @MainActor @Sendable () -> Void
    ) -> Self {
        let deleteAccount: @Sendable (UUID) async throws -> Void = { userId in
            try await services.accountDeletionCoordinator(
                userId: userId,
                signOut: onSignedOut
            ).run()
        }
        return Self(
            library: LibraryTabDependencies(
                bookStore: services.library.bookStore,
                positionStore: services.library.positionStore,
                bookFileStorage: services.library.bookFileStorage,
                importCoordinator: services.library.importCoordinator,
                sampleBookInstaller: services.library.sampleBookInstaller,
                sampleReaderInstaller: services.library.sampleReaderInstaller,
                conversationStore: services.chat.conversationStore,
                messageStore: services.chat.messageStore,
                readerDefaults: services.settings.readerDefaults,
                syncEngine: services.sync.engine,
                sharePackageService: services.library.sharePackageService,
                entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
                entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
                groupID: services.billing.groupID,
                settings: SettingsContentDependencies(
                    workerClient: services.workerClient,
                    readerDefaults: services.settings.readerDefaults,
                    ttsSettingsStore: services.audio.ttsSettingsStore,
                    syncStatus: services.sync.status,
                    syncEngine: services.sync.engine,
                    telemetryStore: services.settings.telemetryStore,
                    footerDetectionStore: services.settings.footerDetectionStore,
                    entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
                    entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
                    restoreService: services.billing.restoreService,
                    manageSubscriptionPresenter: services.billing.manageSubscriptionPresenter,
                    groupID: services.billing.groupID,
                    dataUseConsentStore: services.dataUseConsentStore,
                    onRevokeDataUse: { await services.voice.presenter.requestEnd() },
                    deleteAccount: deleteAccount
                )
            ),
            chatService: services.chat.service,
            messageStore: services.chat.messageStore,
            voicePresenter: services.voice.presenter,
            entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
            dataUseConsentStore: services.dataUseConsentStore,
            deleteAccount: deleteAccount
        )
    }
}

struct SignedInView: View {
    let onLibraryReadyForTrial: () -> Void

    @Environment(\.appDependencies) private var appDependencies
    @Environment(CurrentUserBox.self) private var currentUserBox
    @Environment(\.signOut) private var signOut
#if targetEnvironment(macCatalyst)
    @State private var showUsernameEditor = false
#endif

    private var services: BootstrappedServices? { appDependencies?.services }
    private var user: User? {
        guard case .signedIn(user: let user) = currentUserBox.state else { return nil }
        return user
    }

    init(onLibraryReadyForTrial: @escaping () -> Void = {}) {
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
    }

    var body: some View {
        if let services, let user {
#if targetEnvironment(macCatalyst)
            let editUsername: @MainActor () -> Void = { showUsernameEditor = true }
#else
            let editUsername: @MainActor () -> Void = {}
#endif
            SignedInContent(
                dependencies: SignedInContentDependencies.make(
                    services: services,
                    onSignedOut: { signOut() }
                ),
                user: user,
                onLibraryReadyForTrial: onLibraryReadyForTrial
            )
            .macCommandDispatch(readerDefaults: services.settings.readerDefaults)
            .readerPrefsMenuPublisher(
                services: services,
                user: user,
                onSignedOut: { signOut() },
                account: appDependencies?.macAccountMenu,
                onEditUsername: editUsername
            )
            .accountDeletionAlerts(account: appDependencies?.macAccountMenu)
#if targetEnvironment(macCatalyst)
            .sheet(isPresented: $showUsernameEditor) {
                UsernameEditorView(username: user.username) { username in
                    let updated = try await services.workerClient.send(
                        UserUpdateEndpoint(username: username)
                    )
                    await MainActor.run {
                        currentUserBox.signIn(user: updated)
                    }
                    return updated
                }
            }
#endif
        } else {
            VStack {
#if DEBUG
                Text("Services or user are missing")
#endif
                ProgressView()
            }
        }
    }
}

struct SignedInContent: View {
    let dependencies: SignedInContentDependencies
    let user: User
    let onLibraryReadyForTrial: () -> Void

    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw: String = ""
    @SceneStorage(RishiSceneState.openBookIdKey) private var openBookIdRaw: String = ""
    @Environment(AppRouter.self) private var router
#if targetEnvironment(macCatalyst)
    @Environment(ReaderWindowCoordinator.self) private var readerWindows
#endif
    @State private var model = SignedInViewModel()
    @State private var showDataUseConsent = false
    @State private var dataUseConsentGranted = false
    @State private var retryVoiceAfterConsent = false

    var body: some View {
        @Bindable var model = model
        LibraryTabView(
            dependencies: dependencies.library,
            user: user,
            model: model,
            dataUseConsentGranted: dataUseConsentGranted,
            onLibraryReadyForTrial: onLibraryReadyForTrial
        )
#if targetEnvironment(macCatalyst)
        .task {
            router.onCatalystBookResolved = { book in
                model.hint(book)
                readerWindows.open(book: book, user: user)
            }
        }
        .onDisappear {
            readerWindows.invalidate(userID: user.id)
        }
#endif
        .task(id: user.id) {
            await dependencies.dataUseConsentStore.setCurrentUser(user.id.uuidString)
            dataUseConsentGranted = await dependencies.dataUseConsentStore.isCurrent(for: user.id.uuidString)
            showDataUseConsent = !dataUseConsentGranted
        }
        .sheet(isPresented: $showDataUseConsent) {
            AIDataConsentView(
                onAllow: {
                    Task {
                        await dependencies.dataUseConsentStore.setCurrentUser(user.id.uuidString)
                        await dependencies.dataUseConsentStore.grant(for: user.id.uuidString)
                        dataUseConsentGranted = await dependencies.dataUseConsentStore.isCurrent(for: user.id.uuidString)
                        showDataUseConsent = false
                        NotificationCenter.default.post(name: AppRouter.shareRedemptionReady, object: nil)
                        if retryVoiceAfterConsent {
                            retryVoiceAfterConsent = false
                            await dependencies.voicePresenter.retry()
                        }
                    }
                },
                onNotNow: {
                    retryVoiceAfterConsent = false
                    showDataUseConsent = false
                    dependencies.voicePresenter.clearFailure()
                }
            )
        }
        .sheet(item: $model.selectedConversation) { convo in
            ConversationChatHost(
                vm: ChatPanelViewModel.make(
                    conversation: convo,
                    chatService: dependencies.chatService,
                    messageStore: dependencies.messageStore
                )
            )
        }
        .onChange(of: dependencies.voicePresenter.isPresenting) { _, presenting in
            if !presenting { dependencies.voicePresenter.promotePendingFailure() }
        }
        .alert(
            dependencies.voicePresenter.failure?.title ?? "",
            isPresented: Binding(
                get: { dependencies.voicePresenter.failure != nil },
                set: { if !$0 { dependencies.voicePresenter.clearFailure() } }
            ),
            presenting: dependencies.voicePresenter.failure
        ) { failure in
            switch failure.primaryAction {
            case .requestDataUseConsent:
                Button("Review data use") {
                    retryVoiceAfterConsent = true
                    dependencies.voicePresenter.prepareForDataUseConsent()
                    showDataUseConsent = true
                }
            case .openSettings:
                Button("Open Settings") {
                    Self.openSettings()
                    dependencies.voicePresenter.clearFailure()
                }
            case .retry:
                Button("Try again") { Task { await dependencies.voicePresenter.retry() } }
            case .upgrade:
                Button("See plans") {
                    dependencies.voicePresenter.clearFailure()
                    model.requestPaywall(
                        "voice_chat_exhausted",
                        serverPaidActive: dependencies.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                    )
                }
            case .dismiss:
                Button("OK") { dependencies.voicePresenter.clearFailure() }
            }
            Button("Dismiss", role: .cancel) { dependencies.voicePresenter.clearFailure() }
        } message: { failure in
            Text(failure.message)
        }
#if !targetEnvironment(macCatalyst)
        .sceneRestoration(model: model, tabRaw: $selectedTabRaw, openBookIdRaw: $openBookIdRaw)
#endif
    }

    private static func openSettings() {
#if targetEnvironment(macCatalyst)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            UIApplication.shared.open(url)
        }
#elseif canImport(UIKit) && os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#endif
    }
}

@MainActor
private struct SignedInContentPreviewHost: View {
    private let user = User(
        id: LibraryRootPreviewFixtures.userId,
        email: "reader@example.com",
        name: "Preview Reader"
    )
    @State private var libraryVM = LibraryRootPreviewFixtures.makeViewModel(
        books: LibraryRootPreviewFixtures.populated
    )
    @State private var conversationsVM = ConversationsListViewModel.make(
        conversationStore: InMemoryConversationStore(),
        messageStore: InMemoryMessageStore()
    )

    var body: some View {
        TabView {
            NavigationStack {
                LibraryRootView(
                    importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
                    onOpenBook: { _ in },
                    onShowSettings: {},
                    documentPickerPresented: nil
                )
            }
            .environment(libraryVM)
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                ConversationsListView(
                    viewModel: conversationsVM,
                    userId: user.id,
                    onSelect: { _ in }
                )
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
        }
    }
}

#Preview("Signed-in content") {
    SignedInContentPreviewHost()
}

extension View {

    @ViewBuilder
    func readerPrefsMenuPublisher(
        services: BootstrappedServices,
        user: User,
        onSignedOut: @escaping @MainActor @Sendable () -> Void,
        account: MacAccountMenuModel?,
        onEditUsername: @escaping @MainActor () -> Void = {},
        pdfViewMode: Binding<PDFViewModeSetting>? = nil
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            self.modifier(
                ReaderPrefsMenuPublisher(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut,
                    account: account,
                    onEditUsername: onEditUsername,
                    pdfViewMode: pdfViewMode
                )
            )
        #else
            self
        #endif
    }
}

#if targetEnvironment(macCatalyst)

    private struct ReaderPrefsMenuPublisher: ViewModifier {

        @State private var vm: MacReaderPrefsMenuViewModel
        let services: BootstrappedServices
        let user: User
        let onSignedOut: @MainActor @Sendable () -> Void
        let account: MacAccountMenuModel?
        let onEditUsername: @MainActor () -> Void
        let pdfViewMode: Binding<PDFViewModeSetting>?

        init(
            services: BootstrappedServices,
            user: User,
            onSignedOut: @escaping @MainActor @Sendable () -> Void,
            account: MacAccountMenuModel?,
            onEditUsername: @escaping @MainActor () -> Void,
            pdfViewMode: Binding<PDFViewModeSetting>?
        ) {
            self.services = services
            self.onSignedOut = onSignedOut
            _vm = State(
                wrappedValue: MacReaderPrefsMenuViewModel(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut
                )
            )
            self.user = user
            self.account = account
            self.onEditUsername = onEditUsername
            self.pdfViewMode = pdfViewMode
        }

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(
                    \.readerPrefsMenu,
                    vm.makeModel(pdfViewModeOverride: pdfViewMode)
                )
                .task(id: user.id) { await vm.seed() }

                .onAppear { updateAccountPayload() }
                .onChange(of: services.billing.entitlementSnapshotStore.resolution) { _, _ in
                    updateAccountPayload()
                }
                .onChange(of: user.username) { _, _ in
                    vm.updateUsername(user.username)
                    updateAccountPayload()
                }
                .onDisappear { account?.clear() }
        }

        private func updateAccountPayload() {
            let action: MacAccountMenuModel.SubscriptionAction
            if let snapshot = services.billing.entitlementSnapshotStore.resolvedSnapshot {
                action = snapshot.isPaidActive ? .manage : .subscribe
            } else {
                action = .unavailable
            }
            var payload = vm.makeAccountPayload(subscriptionAction: action)
            payload.onDeleteAccount = { account?.requestDelete() }
            payload.onEditUsername = onEditUsername
            account?.onDeleteConfirmed = {
                try await services.accountDeletionCoordinator(
                    userId: user.id,
                    signOut: onSignedOut
                ).run()
            }
            account?.update(payload)
        }
    }

#endif

private extension View {
    @ViewBuilder
    func accountDeletionAlerts(account: MacAccountMenuModel?) -> some View {
        #if targetEnvironment(macCatalyst)
        self
            .alert(
                "Delete Account?",
                isPresented: Binding(
                    get: { account?.deleteConfirmationPresented == true },
                    set: { account?.deleteConfirmationPresented = $0 }
                )
            ) {
                Button("Delete", role: .destructive) {
                    Task { await account?.confirmDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your account, your library, your highlights, and your conversations. This cannot be undone.")
            }
            .alert(
                "Couldn't delete your account",
                isPresented: Binding(
                    get: { account?.deleteError != nil },
                    set: { if !$0 { account?.deleteError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(account?.deleteError ?? "")
            }
        #else
        self
        #endif
    }
}

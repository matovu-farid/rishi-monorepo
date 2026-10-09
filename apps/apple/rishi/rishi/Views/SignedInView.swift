










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
        appDependencies: AppDependencies,
        credentialSnapshot: CredentialSnapshot,
        accountIdentity: LibraryAccountIdentity,
        currentAccountIdentity: @escaping @MainActor () -> LibraryAccountIdentity?,
        onSignedOut: @escaping @MainActor @Sendable () -> Void
    ) throws -> Self {
        let authority = appDependencies.credentialAuthority
        _ = try authority.snapshot(for: .normal(credentialSnapshot.lease))
        guard appDependencies.activeAccountIdentity == accountIdentity else { throw CredentialAuthenticationFailure.accountChanged }
        let consent = CredentialBoundDataUseConsentStore(store: services.dataUseConsentStore, authority: authority, lease: credentialSnapshot.lease)
        let sharedAPI = try services.sharedReadingAPIFactory(.normal(credentialSnapshot.lease))
        let deletion = try appDependencies.accountDeletionCoordinator(snapshot: credentialSnapshot, accountIdentity: accountIdentity, publishSignedOut: onSignedOut)
        let deleteAccount: @Sendable (UUID) async throws -> Void = { userId in
            guard userId == accountIdentity.userID else { throw CredentialAuthenticationFailure.accountChanged }
            try await deletion.run()
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
                bookSourceRegistry: services.library.bookSourceRegistry,
                bookImportLifecycle: services.library.bookImportLifecycle,
                bookMaterializationCoordinator: services.library.bookMaterializationCoordinator,
                bookImportRecovery: services.library.bookImportRecovery,
                bookImportEvents: services.library.bookImportEvents,
                currentAccountGeneration: services.library.currentAccountGeneration,
                credentialAuthority: authority,
                credentialSnapshot: credentialSnapshot,
                accountIdentity: accountIdentity,
                currentAccountIdentity: currentAccountIdentity,
                sharedReadingAPI: sharedAPI,
                sharedReadingSessionRegistry: services.sharedReadingSessionRegistry,
                sessionBookService: services.library.sessionBookService,
                entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
                entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
                voicePresenter: services.voice.presenter,
                groupID: services.billing.groupID,
                settings: SettingsContentDependencies(
                    credentialAuthority: authority, credentialSnapshot: credentialSnapshot,
                    customerEntitlements: services.billing.customerEntitlements, store: services.billing.store,
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
                    dataUseConsentStore: consent,
                    onRevokeDataUse: {
                        do { try await services.voice.presenter.requestEnd(credentialContext: .normal(credentialSnapshot.lease)) }
                        catch CredentialAuthenticationFailure.accountChanged { }
                        catch is CancellationError { }
                        catch { Log.error("voice.consent_revoke.failed", error: error) }
                    },
                    deleteAccount: deleteAccount
                )
            ),
            chatService: services.chat.service,
            messageStore: services.chat.messageStore,
            voicePresenter: services.voice.presenter,
            entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
            dataUseConsentStore: consent,
            deleteAccount: deleteAccount
        )
    }
}

struct SignedInView: View {
    let onLibraryReadyForTrial: () -> Void

    @Environment(\.appDependencies) private var appDependencies
    @Environment(CurrentUserBox.self) private var currentUserBox
    @Environment(TrialIntroPresentationState.self) private var trialPresentationState
    @Environment(IncomingBookPresentationReadiness.self) private var incomingReadiness
    @Environment(\.signOut) private var signOut
    @State private var trialRegistration: TrialIntroPresentationState.Registration?
    @State private var incomingReadinessOwner: UUID?
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
        if let services, let user,
           let appDependencies,
           let accountIdentity = appDependencies.activeAccountIdentity,
           accountIdentity.userID == user.id,
           let snapshot = try? appDependencies.credentialAuthority.snapshot(),
           DerivedUserID.from(snapshot.lease.rawUserID) == user.id,
           let contentDependencies = try? SignedInContentDependencies.make(
                services: services, appDependencies: appDependencies, credentialSnapshot: snapshot,
                accountIdentity: accountIdentity,
                currentAccountIdentity: { [weak appDependencies] in appDependencies?.activeAccountIdentity },
                onSignedOut: { currentUserBox.signedOutAfterCredentialClear() }) {
#if targetEnvironment(macCatalyst)
            let editUsername: @MainActor () -> Void = { showUsernameEditor = true }
#else
            let editUsername: @MainActor () -> Void = {}
#endif
            SignedInContent(
                dependencies: contentDependencies,
                user: user,
                onLibraryReadyForTrial: onLibraryReadyForTrial
            )
            .id(accountIdentity)
            .id(snapshot.lease)
            .macCommandDispatch(readerDefaults: services.settings.readerDefaults)
            .readerPrefsMenuPublisher(
                services: services,
                user: user,
                onSignedOut: { signOut() },
                deleteAccount: { try await contentDependencies.deleteAccount(user.id) },
                account: appDependencies.macAccountMenu,
                onEditUsername: editUsername
            )
            .accountDeletionAlerts(account: appDependencies.macAccountMenu)
            .onAppear {
                incomingReadinessOwner = incomingReadiness.claimOwnership(of: .signedInView)
                reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies)
                guard trialRegistration == nil else { return }
                trialRegistration = trialPresentationState.register(.signedIn, identity: accountIdentity) { [weak appDependencies, weak currentUserBox] in
                    var safety = TrialChildSafety()
                    let currentUserID: UUID?
                    if case .signedIn(user: let user)? = currentUserBox?.state {
                        currentUserID = user.id
                    } else {
                        currentUserID = nil
                    }
                    let accountMatches = currentUserID == accountIdentity.userID
                        && appDependencies?.activeAccountIdentity == accountIdentity
                    safety.consent = true
                    safety.conversation = true
                    safety.voice = true
                    safety.libraryReady = true
                    safety.libraryModal = true
                    safety.firstBookFlowActive = false
#if targetEnvironment(macCatalyst)
                    let account = appDependencies?.macAccountMenu
                    safety.signedIn = NoCardTrialPresentationPolicy.signedInSourceIsSafe(
                        accountMatches: accountMatches,
                        catalystModelAvailable: account != nil,
                        usernameEditorPresented: showUsernameEditor,
                        accountDeleteConfirmationPresented: account?.deleteConfirmationPresented == true,
                        accountDeleteErrorPresented: account?.deleteError != nil
                    )
#else
                    safety.signedIn = NoCardTrialPresentationPolicy.signedInSourceIsSafe(
                        accountMatches: accountMatches
                    )
#endif
                    return safety
                }
            }
            .onDisappear {
                incomingReadiness.withdraw(.signedInView, owner: incomingReadinessOwner)
                incomingReadinessOwner = nil
                guard let trialRegistration else { return }
                trialPresentationState.unregister(
                    trialRegistration,
                    deferredUnderCover: trialPresentationState.activeOwnedCoverClaimID
                )
                self.trialRegistration = nil
            }
            .onChange(of: appDependencies.activeAccountIdentity) { _, identity in
                if identity == accountIdentity {
                    reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies)
                } else {
                    incomingReadiness.withdraw(.signedInView, owner: incomingReadinessOwner)
                }
            }
#if targetEnvironment(macCatalyst)
            .onChange(of: showUsernameEditor) { _, _ in trialPresentationState.update(); reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies) }
            .onChange(of: appDependencies.macAccountMenu.deleteConfirmationPresented) { _, _ in
                trialPresentationState.update(); reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies)
            }
            .onChange(of: appDependencies.macAccountMenu.deleteError) { _, _ in
                trialPresentationState.update(); reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies)
            }
            .onChange(of: appDependencies.macAccountMenu.isDeletingAccount) { _, _ in
                trialPresentationState.update(); reportIncomingReadiness(accountIdentity: accountIdentity, appDependencies: appDependencies)
            }
#endif
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

    private func reportIncomingReadiness(accountIdentity: LibraryAccountIdentity, appDependencies: AppDependencies) {
        var blockers = Set<IncomingBookPresentationReadiness.Blocker>()
        let matches = user?.id == accountIdentity.userID && appDependencies.activeAccountIdentity == accountIdentity
        if !matches { blockers.insert(.identityMismatch) }
        #if targetEnvironment(macCatalyst)
        if showUsernameEditor { blockers.insert(.username) }
        if appDependencies.macAccountMenu.deleteConfirmationPresented
            || appDependencies.macAccountMenu.isDeletingAccount { blockers.insert(.accountDeletion) }
        if appDependencies.macAccountMenu.deleteError != nil { blockers.insert(.accountError) }
        #endif
        incomingReadiness.report(.signedInView, identity: accountIdentity, blockers: blockers, owner: incomingReadinessOwner)
    }
}

struct SignedInContent: View {
    let dependencies: SignedInContentDependencies
    let user: User
    let onLibraryReadyForTrial: () -> Void

    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw: String = ""
    @SceneStorage(RishiSceneState.openBookIdKey) private var openBookIdRaw: String = ""
    @Environment(AppRouter.self) private var router
    @Environment(TrialIntroPresentationState.self) private var trialPresentationState
    @Environment(IncomingBookPresentationReadiness.self) private var incomingReadiness
#if targetEnvironment(macCatalyst)
    @Environment(ReaderWindowCoordinator.self) private var readerWindows
#endif
    @State private var model = SignedInViewModel()
    @State private var showDataUseConsent = false
    @State private var dataUseConsentGranted = false
    @State private var retryVoiceAfterConsent = false
    @State private var trialRegistration: TrialIntroPresentationState.Registration?
    @State private var incomingReadinessOwner: UUID?

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
                dependencies.voicePresenter.scheduleRegisteredReaderCleanup()
                readerWindows.open(book: book, user: user)
            }
            router.onCatalystSharedReaderPresented = { presentation in
                dependencies.voicePresenter.scheduleRegisteredReaderCleanup()
                return readerWindows.openShared(presentation)
            }
            readerWindows.configureSharedReading(
                contextLookup: { windowID, routeID in
                    router.sharedReaderPresentation(id: routeID, accountID: windowID.userID)?.context
                },
                close: { routeID, accountID in
                    router.closeSharedReader(id: routeID, accountID: accountID)
                }
            )
            if let route = router.catalystSharedReaderRoute,
               let presentation = router.sharedReaderPresentation(for: route, accountID: user.id) {
                readerWindows.openShared(presentation)
            }
        }
        .onDisappear {
            readerWindows.invalidate(userID: user.id)
        }
        .onChange(of: readerWindows.openWindows.isEmpty) { wasEmpty, isEmpty in
            guard !wasEmpty, isEmpty else { return }
            Task { await dependencies.voicePresenter.cleanupRegisteredReaderSessions() }
        }
#else
        .onChange(of: router.path.isEmpty) { wasEmpty, isEmpty in
            guard !wasEmpty, isEmpty else { return }
            Task { await dependencies.voicePresenter.cleanupRegisteredReaderSessions() }
        }
#endif
        .task(id: user.id) {
            await dependencies.dataUseConsentStore.setCurrentUser(user.id.uuidString)
            let granted = await dependencies.dataUseConsentStore.isCurrent(for: user.id.uuidString)
            _ = dependencies.library.credentialAuthority.performIfCurrent(dependencies.library.credentialSnapshot.lease) {
                dataUseConsentGranted = granted
                showDataUseConsent = !granted
            }
        }
        .onAppear {
            incomingReadinessOwner = incomingReadiness.claimOwnership(of: .signedInContent)
            reportIncomingReadiness()
            guard trialRegistration == nil else { return }
            trialRegistration = trialPresentationState.register(.signedInContent, identity: dependencies.library.accountIdentity) {
                var safety = TrialChildSafety()
                safety.signedIn = true
                safety.consent = dataUseConsentGranted && !showDataUseConsent
                safety.conversation = model.selectedConversation == nil
                safety.voice = !dependencies.voicePresenter.isPresenting && dependencies.voicePresenter.failure == nil
                safety.libraryReady = true
                safety.libraryModal = true
                safety.firstBookFlowActive = false
                return safety
            }
        }
        .onDisappear {
            incomingReadiness.withdraw(.signedInContent, owner: incomingReadinessOwner)
            incomingReadinessOwner = nil
            guard let trialRegistration else { return }
            trialPresentationState.unregister(
                trialRegistration,
                deferredUnderCover: trialPresentationState.activeOwnedCoverClaimID
            )
            self.trialRegistration = nil
        }
        .onChange(of: dataUseConsentGranted) { _, _ in trialPresentationState.update(); reportIncomingReadiness() }
        .onChange(of: showDataUseConsent) { _, _ in trialPresentationState.update(); reportIncomingReadiness() }
        .onChange(of: model.selectedConversation?.id) { _, _ in trialPresentationState.update(); reportIncomingReadiness() }
        .onChange(of: dependencies.voicePresenter.isPresenting) { _, _ in trialPresentationState.update(); reportIncomingReadiness() }
        .onChange(of: dependencies.voicePresenter.failure) { _, _ in trialPresentationState.update(); reportIncomingReadiness() }
        .sheet(isPresented: $showDataUseConsent) {
            AIDataConsentView(
                onAllow: {
                    Task {
                        await dependencies.dataUseConsentStore.setCurrentUser(user.id.uuidString)
                        await dependencies.dataUseConsentStore.grant(for: user.id.uuidString)
                        let granted = await dependencies.dataUseConsentStore.isCurrent(for: user.id.uuidString)
                        guard granted, dependencies.library.credentialAuthority.isCurrent(dependencies.library.credentialSnapshot.lease) else { return }
                        dataUseConsentGranted = granted
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
            reportIncomingReadiness()
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
                        .voiceChatExhausted,
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

    private func reportIncomingReadiness() {
        let identity = dependencies.library.accountIdentity
        var blockers = Set<IncomingBookPresentationReadiness.Blocker>()
        if !dataUseConsentGranted || showDataUseConsent { blockers.insert(.consent) }
        if model.selectedConversation != nil { blockers.insert(.conversation) }
        if dependencies.voicePresenter.isPresenting { blockers.insert(.voice) }
        if dependencies.voicePresenter.failure != nil { blockers.insert(.voiceError) }
        incomingReadiness.report(.signedInContent, identity: identity, blockers: blockers, owner: incomingReadinessOwner)
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
        .task { await libraryVM.refresh() }
        .environment(TrialIntroPresentationState())
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
        deleteAccount: @escaping @MainActor @Sendable () async throws -> Void,
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
                    deleteAccount: deleteAccount,
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
        let deleteAccount: @MainActor @Sendable () async throws -> Void
        let account: MacAccountMenuModel?
        let onEditUsername: @MainActor () -> Void
        let pdfViewMode: Binding<PDFViewModeSetting>?

        init(
            services: BootstrappedServices,
            user: User,
            onSignedOut: @escaping @MainActor @Sendable () -> Void,
            deleteAccount: @escaping @MainActor @Sendable () async throws -> Void,
            account: MacAccountMenuModel?,
            onEditUsername: @escaping @MainActor () -> Void,
            pdfViewMode: Binding<PDFViewModeSetting>?
        ) {
            self.services = services
            self.onSignedOut = onSignedOut
            self.deleteAccount = deleteAccount
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
            account?.onDeleteConfirmed = deleteAccount
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

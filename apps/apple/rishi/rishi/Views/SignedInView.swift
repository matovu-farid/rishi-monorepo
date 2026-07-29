










import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct SignedInView: View {
    let onLibraryReadyForTrial: () -> Void

    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw:
    String = ""
    @SceneStorage(RishiSceneState.openBookIdKey) private var openBookIdRaw:
    String = ""
  
    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var appDependencies
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif

    @Environment(CurrentUserBox.self) private var currentUserBox
    @Environment(\.signOut) private var signOut

    var services: BootstrappedServices? {appDependencies?.services}
    var user: User? {
        guard case .signedIn(user: let user) = currentUserBox.state else {return nil}
        return user
    }
    
    @State private var model = SignedInViewModel()

    init(onLibraryReadyForTrial: @escaping () -> Void = {}) {
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
    }

    var body: some View {
        if let services, let user  {
            
            @Bindable var model = model
            LibraryTabView(
                dependencies: LibraryTabDependencies(
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
                    entitlementSnapshotStore: services.billing.entitlementSnapshotStore,
                    entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
                    groupID: services.billing.groupID,
                    settings: SettingsContentDependencies(
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
                        groupID: services.billing.groupID
                    )
                ),
                user: user,
                model: model,
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
            
            .sheet(item: $model.selectedConversation) { convo in
                ConversationChatHost(
                    vm: ChatPanelViewModel.make(
                        conversation: convo,
                        chatService: services.chat.service,
                        messageStore: services.chat.messageStore
                    )
                )
            }
            
            .onChange(of: services.voice.presenter.isPresenting) { _, presenting in
                if !presenting {
                    services.voice.presenter.promotePendingFailure()
                }
            }

            .alert(
                voiceFailureTitle,
                isPresented: Binding(
                    get: { services.voice.presenter.failure != nil },
                    set: { presented in
                        if presented == false {
                            services.voice.presenter.clearFailure()
                        }
                    }
                ),
                presenting: services.voice.presenter.failure
            ) { failure in
                switch failure.primaryAction {
                case .openSettings:
                    Button("Open Settings") {
                        Self.openSettings()
                        services.voice.presenter.clearFailure()
                    }
                case .retry:
                    Button("Try again") {
                        
                        Task { await services.voice.presenter.retry() }
                    }
                case .upgrade:
                    Button("See plans") {
                        services.voice.presenter.clearFailure()
                        model.requestPaywall(
                            "voice_chat_exhausted",
                            serverPaidActive: services.billing.entitlementSnapshotStore
                                .resolvedSnapshot?.isPaidActive ?? false
                        )
                    }
                case .dismiss:
                    Button("OK") {
                        services.voice.presenter.clearFailure()
                    }
                }
                Button("Dismiss", role: .cancel) {
                    services.voice.presenter.clearFailure()
                }
            } message: { failure in
                Text(failure.message)
            }
            .macCommandDispatch(readerDefaults: services.settings.readerDefaults)

            .readerPrefsMenuPublisher(
                services: services,
                user: user,
                onSignedOut: { signOut() },
                account: appDependencies?.macAccountMenu
            )
            
            #if !targetEnvironment(macCatalyst)
                .sceneRestoration(
                    model: model,
                    tabRaw: $selectedTabRaw,
                    openBookIdRaw: $openBookIdRaw
                )
            #endif
        }
        else {
            VStack{
#if DEBUG
                Text("Services or user are missing")
#endif
                ProgressView()
            }
        }
    }
       

    private var voiceFailureTitle: String {
        services?.voice.presenter.failure?.title ?? ""
    }

    private static func openSettings() {
        #if targetEnvironment(macCatalyst)
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                UIApplication.shared.open(url)
            }
        #elseif canImport(UIKit) && os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        #endif
    }

}

extension View {

    @ViewBuilder
    func readerPrefsMenuPublisher(
        services: BootstrappedServices,
        user: User,
        onSignedOut: @escaping () -> Void,
        account: MacAccountMenuModel?,
        pdfViewMode: Binding<PDFViewModeSetting>? = nil
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            self.modifier(
                ReaderPrefsMenuPublisher(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut,
                    account: account,
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
        let account: MacAccountMenuModel?
        let pdfViewMode: Binding<PDFViewModeSetting>?

        init(
            services: BootstrappedServices,
            user: User,
            onSignedOut: @escaping () -> Void,
            account: MacAccountMenuModel?,
            pdfViewMode: Binding<PDFViewModeSetting>?
        ) {
            self.services = services
            _vm = State(
                wrappedValue: MacReaderPrefsMenuViewModel(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut
                )
            )
            self.user = user
            self.account = account
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
                .onDisappear { account?.clear() }
        }

        private func updateAccountPayload() {
            let action: MacAccountMenuModel.SubscriptionAction
            if let snapshot = services.billing.entitlementSnapshotStore.resolvedSnapshot {
                action = snapshot.isPaidActive ? .manage : .subscribe
            } else {
                action = .unavailable
            }
            account?.update(vm.makeAccountPayload(subscriptionAction: action))
        }
    }

#endif

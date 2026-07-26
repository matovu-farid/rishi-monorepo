










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
                services: services,
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
                        services: services
                    )
                )
            }
            
            .onChange(of: services.voicePresenter.isPresenting) { _, presenting in
                if !presenting {
                    services.voicePresenter.promotePendingFailure()
                }
            }

            .alert(
                voiceFailureTitle,
                isPresented: Binding(
                    get: { services.voicePresenter.failure != nil },
                    set: { presented in
                        if presented == false {
                            services.voicePresenter.clearFailure()
                        }
                    }
                ),
                presenting: services.voicePresenter.failure
            ) { failure in
                switch failure.primaryAction {
                case .openSettings:
                    Button("Open Settings") {
                        Self.openSettings()
                        services.voicePresenter.clearFailure()
                    }
                case .retry:
                    Button("Try again") {
                        
                        Task { await services.voicePresenter.retry() }
                    }
                case .upgrade:
                    Button("See plans") {
                        services.voicePresenter.clearFailure()
                        model.requestPaywall(
                            "voice_chat_exhausted",
                            serverPaidActive: services.entitlementSnapshotStore
                                .resolvedSnapshot?.isPaidActive ?? false
                        )
                    }
                case .dismiss:
                    Button("OK") {
                        services.voicePresenter.clearFailure()
                    }
                }
                Button("Dismiss", role: .cancel) {
                    services.voicePresenter.clearFailure()
                }
            } message: { failure in
                Text(failure.message)
            }
            
     
            
            .macCommandDispatch(readerDefaults: services.readerDefaults)
            
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
        services?.voicePresenter.failure?.title ?? ""
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
        account: MacAccountMenuModel?
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            self.modifier(
                ReaderPrefsMenuPublisher(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut,
                    account: account
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
        let user: User
        let account: MacAccountMenuModel?

        init(
            services: BootstrappedServices,
            user: User,
            onSignedOut: @escaping () -> Void,
            account: MacAccountMenuModel?
        ) {
            _vm = State(
                wrappedValue: MacReaderPrefsMenuViewModel(
                    services: services,
                    user: user,
                    onSignedOut: onSignedOut
                )
            )
            self.user = user
            self.account = account
        }

        func body(content: Content) -> some View {
            content
                .focusedSceneValue(\.readerPrefsMenu, vm.makeModel())
                .task(id: user.id) { await vm.seed() }

                .onAppear { account?.update(vm.makeAccountPayload()) }
                .onDisappear { account?.clear() }
        }
    }

#endif

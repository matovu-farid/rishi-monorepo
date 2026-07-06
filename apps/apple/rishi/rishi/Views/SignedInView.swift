import RishiAudio
import RishiAuth
import RishiBilling
import RishiChat
import RishiCore
import RishiOnboarding
import RishiReader
import RishiSettings
import RishiSync
import RishiUIKit
import RishiVoice
import SwiftUI
import RishiLibrary

#if canImport(UIKit)
    import UIKit
#endif

struct SignedInView: View {
    @SceneStorage(RishiSceneState.selectedTabKey) private var selectedTabRaw:
    String = ""
    @SceneStorage(RishiSceneState.openBookIdKey) private var openBookIdRaw:
    String = ""
  
    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var appDependencies

    @Environment(CurrentUserBox.self) private var currentUserBox
    var services: BootstrappedServices? {appDependencies?.services}
    var user: User? {
        guard case .signedIn(user: let user) = currentUserBox.state else {return nil}
        return user
    }
    
    private var libraryVM: LibraryViewModel? {
        guard let services = appDependencies?.services, case .signedIn(user: let user) = currentUserBox.state else {
            return nil
        }
        return LibraryViewModel.make(services: services, user: user)
        
    }
    


  

    @State private var model = SignedInViewModel()

    var body: some View {
        if let services, let user, let libraryVM  {
            
            @Bindable var model = model
            LibraryTabView(
                services: services,
                user: user,
                model: model
            )
            .environment(libraryVM)
            
            .sheet(item: $model.selectedConversation) { convo in
                ConversationChatHost(
                    vm: ChatPanelViewModel.make(
                        conversation: convo,
                        services: services
                    )
                )
            }
            
            .fullScreenCover(
                isPresented: Binding(
                    get: { services.voicePresenter.isPresenting },
                    set: { newValue in
                        if newValue == false {
                            
                            Task { await services.voicePresenter.end() }
                        }
                    }
                ),
                onDismiss: {
                    
                    services.voicePresenter.promotePendingFailure()
                }
            ) {
                VoiceSessionHost(
                    presenter: services.voicePresenter,
                    services: services,
                    userId: user.id
                )
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
                account: appDependencies?.macAccountMenu
            )
            
            .sceneRestoration(
                model: model,
                tabRaw: $selectedTabRaw,
                openBookIdRaw: $openBookIdRaw
            )
        }
        else {
            VStack{
#if DEBUG
                Text("Services or user or Library VM are missing")
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

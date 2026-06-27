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

#if canImport(UIKit)
    import UIKit
#endif

struct SignedInView: View {

    let services: BootstrappedServices
    let user: User

    @Binding var selectedTabRaw: String
    @Binding var openBookIdRaw: String

    let onSignedOut: () -> Void

    let onCacheUserId: (UserID) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.appDependencies) private var appDependencies

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
    }

    @State private var model = SignedInViewModel()

    var body: some View {
        @Bindable var model = model
        LibraryTabView(
            services: services,
            user: user,
            model: model,
            onCacheUserId: onCacheUserId
        )
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

        //        .sheet(item: $model.paywallFeature) { feature in
        ////            PaywallHost(
        ////                feature: feature,
        ////                vm: PaywallViewModel.make(services: services),
        ////                onDismiss: { model.dismissPaywall() }
        ////            )
        //        }

        .macCommandDispatch(readerDefaults: services.readerDefaults)

        .readerPrefsMenuPublisher(
            services: services,
            user: user,
            onSignedOut: onSignedOut,
            account: appDependencies?.macAccountMenu
        )

        .sceneRestoration(
            model: model,
            tabRaw: $selectedTabRaw,
            openBookIdRaw: $openBookIdRaw
        )
    }

    private var voiceFailureTitle: String {
        services.voicePresenter.failure?.title ?? ""
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

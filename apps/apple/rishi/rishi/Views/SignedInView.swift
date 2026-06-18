//
//  SignedInView.swift
//  rishi
//
//  Extracted from RootView (refactor). Owns the signed-in composition shell:
//  the LibraryTabView (library NavigationStack + reader destinations + settings
//  sheet + deep-link onOpenURL), all signed-in modal sheets (chat, paywall),
//  scene-restoration task, and Mac-command intent dispatch.
//
//  RootView retains only the auth-switch branch (loading / signed-in /
//  signed-out) and the onboarding cover which spans both auth states.
//

import SwiftUI
import RishiCore
import RishiAuth
import RishiAudio
import RishiBilling
import RishiChat
import RishiOnboarding
import RishiReader
import RishiSettings
import RishiSync
import RishiUIKit
import RishiVoice
#if canImport(UIKit)
import UIKit
#endif

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

    // MARK: - Signed-in @State

    /// Shell presentation state: conversation sheet, paywall sheet, settings
    /// sheet, and transient book-hint cache. Extracted into a viewModel so
    /// these concerns are unit-testable independently of the view.
    @State private var model = SignedInViewModel()

    // MARK: - Body

    var body: some View {
        @Bindable var model = model
        LibraryTabView(
            services: services,
            user: user,
            model: model,
            onCacheUserId: onCacheUserId,
            onShowChats: { router.showConversations() },
            onSignedOut: onSignedOut
        )
        .sheet(item: $model.selectedConversation) { convo in
            ConversationChatHost(
                vm: ChatPanelViewModel.make(conversation: convo, services: services)
            )
        }
        // Voice is the primary AI surface: the reader toolbar voice button
        // launches a session via `ReaderVoiceEntry` -> `VoiceSessionPresenter`,
        // flipping `isPresenting`. This cover hosts the session and its
        // in-voice text-chat sheet.
        .fullScreenCover(isPresented: Binding(
            get: { services.voicePresenter.isPresenting },
            set: { newValue in
                if newValue == false {
                    // KEEP: presenter.end() is @MainActor; tears down the
                    // cover binding + releases the audio session. UI-bound.
                    Task { await services.voicePresenter.end() }
                }
            }
        ), onDismiss: {
            // The cover has finished dismissing. If it came down because the
            // session failed, publish the pending failure NOW so the native
            // `.alert` presents on a view with no in-flight cover transition
            // (presenting it while the cover was still dismissing dropped it).
            // No-op for a normal session end.
            services.voicePresenter.promotePendingFailure()
        }) {
            VoiceSessionHost(
                presenter: services.voicePresenter,
                services: services,
                userId: user.id
            )
        }
        // Voice-session failure surface. Replaces the deleted full-screen
        // `VoiceErrorView`: on `.failed` the presenter unmounts the cover and
        // publishes `failure`, which this native `.alert` renders ON the
        // library/reader underneath. Dismiss / Try again / Open Settings route
        // back through the single presenter.
        .alert(
            voiceFailureTitle,
            isPresented: Binding(
                get: { services.voicePresenter.failure != nil },
                set: { presented in
                    if presented == false { services.voicePresenter.clearFailure() }
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
                    // KEEP: presenter.retry() is @MainActor; preserves the book
                    // context + prefilled quote so the retried session is not
                    // degraded to bookId-only.
                    Task { await services.voicePresenter.retry() }
                }
            }
            Button("Dismiss", role: .cancel) {
                services.voicePresenter.clearFailure()
            }
        } message: { failure in
            Text(failure.message)
        }
        // BILL-04 — paywall sheet.
        .sheet(item: $model.paywallFeature) { feature in
            PaywallHost(
                feature: feature,
                vm: PaywallViewModel.make(services: services),
                onDismiss: { model.dismissPaywall() }
            )
        }
        // Phase 12 Plan 12-01 — drain the Mac command router on every intent change.
        .macCommandDispatch(readerDefaults: services.readerDefaults)
        // Phase 33 Plan 33-03 (Wave 3) — publish the reader-preference menu
        // model as a focused scene value so `RishiMenuCommands` helper Views can
        // read it via `@FocusedValue(\.readerPrefsMenu)` and render LIVE native
        // checkmarks. Built ONLY from the post-bootstrap `services` + the live
        // `audioPrefs` holder; the focused value is `nil` until this live view
        // mounts, which disables the menu items pre-bootstrap for free.
        // Catalyst-only: iOS keeps the in-app gear + settings sheet untouched.
        .readerPrefsMenuPublisher(services: services, user: user, onSignedOut: onSignedOut, account: appDependencies?.macAccountMenu)
        // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader cover,
        // and persist the latest scene state on every visible path change.
        .sceneRestoration(
            model: model,
            tabRaw: $selectedTabRaw,
            openBookIdRaw: $openBookIdRaw
        )
    }

    // MARK: - Voice failure alert helpers

    /// Title for the voice-failure `.alert`. The `presenting:` form passes the
    /// `VoiceFailureAlert` only to the actions/message closures, not the title,
    /// so the title is resolved here from the same published value (empty when
    /// no failure is active, which is fine — the alert is hidden then).
    private var voiceFailureTitle: String {
        services.voicePresenter.failure?.title ?? ""
    }

    /// Deep-link to the OS privacy settings for the `.micDenied` affordance.
    /// Lives in the app target (which can import UIKit) because
    /// `VoiceFailureAlert` is kept pure.
    ///
    /// iOS opens the app's own Settings page via `openSettingsURLString`. macOS
    /// (Mac Catalyst) has NO per-app Settings bundle, so that iOS URL
    /// (`app-settings:`) is a silent no-op there — instead deep-link to System
    /// Settings -> Privacy & Security -> Microphone.
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

// MARK: - Reader-preference menu publishing (Phase 33 Plan 33-03, Wave 3)

extension View {
    /// Publishes the `readerPrefsMenu` focused scene value on Mac Catalyst and
    /// seeds/persists the live audio holder via `MacReaderPrefsMenuViewModel`;
    /// a no-op on iOS (which keeps the in-app gear + settings sheet).
    @ViewBuilder
    func readerPrefsMenuPublisher(
        services: BootstrappedServices,
        user: User,
        onSignedOut: @escaping () -> Void,
        account: MacAccountMenuModel?
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        self.modifier(
            ReaderPrefsMenuPublisher(services: services, user: user, onSignedOut: onSignedOut, account: account)
        )
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)

/// Catalyst-only modifier that publishes the scene-scoped `ReaderPrefsMenuModel`
/// focused value and pushes the app-GLOBAL account payload into the
/// focus-independent `MacAccountMenuModel`. All service work (sign-out, StoreKit
/// present, manual sync, TTS-settings seed/persist) lives in the owned
/// `MacReaderPrefsMenuViewModel` — this modifier only expresses UI intent.
///
/// The account payload deliberately does NOT ride the focused value: it resolved
/// to nil when the menu bar opened (focus left the content view), greying out
/// the Account submenu while signed in.
private struct ReaderPrefsMenuPublisher: ViewModifier {

    @State private var vm: MacReaderPrefsMenuViewModel
    let user: User
    let account: MacAccountMenuModel?

    init(services: BootstrappedServices, user: User, onSignedOut: @escaping () -> Void, account: MacAccountMenuModel?) {
        _vm = State(wrappedValue: MacReaderPrefsMenuViewModel(
            services: services,
            user: user,
            onSignedOut: onSignedOut
        ))
        self.user = user
        self.account = account
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.readerPrefsMenu, vm.makeModel())
            .task(id: user.id) { await vm.seed() }
            // App-GLOBAL account payload: pushed into the focus-independent
            // model while the signed-in view is present, cleared on disappear
            // (sign-out / teardown) so the submenu disables itself.
            .onAppear { account?.update(vm.makeAccountPayload()) }
            .onDisappear { account?.clear() }
    }
}

#endif

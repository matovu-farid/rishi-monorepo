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
import RishiBilling
import RishiChat
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
        )) {
            VoiceSessionHost(
                presenter: services.voicePresenter,
                services: services,
                userId: user.id
            )
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
        // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader cover,
        // and persist the latest scene state on every visible path change.
        .sceneRestoration(
            services: services,
            model: model,
            tabRaw: $selectedTabRaw,
            openBookIdRaw: $openBookIdRaw
        )
    }

}

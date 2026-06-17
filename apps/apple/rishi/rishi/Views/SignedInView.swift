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

    /// Phase 33 Plan 33-03 (Wave 3) — live source for the Mac menu's Audio
    /// voice/speed checkmarks. `TTSSettings` is immutable + loaded async per
    /// userId via `TTSSettingsStore`, so we hold the live values in a small
    /// `@Observable` seeded on appear and persisted on every change. The
    /// `ReaderPrefsMenuModel` voice/speed `Binding`s read/write THIS holder,
    /// whose setters fan out to `store.save(_, userId:)`. Declared on every
    /// target (harmless/unused on iOS) so the publisher modifier signature is
    /// uniform; only the Catalyst publisher reads it.
    @State private var macAudioPrefs = AudioMenuPrefs()

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
        .readerPrefsMenuPublisher(services: services, user: user, audioPrefs: macAudioPrefs, onSignedOut: onSignedOut, account: appDependencies?.macAccountMenu)
        // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader cover,
        // and persist the latest scene state on every visible path change.
        .sceneRestoration(
            services: services,
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

/// Live holder for the Mac menu's Audio voice/speed selection. `TTSSettings`
/// is immutable + loaded async per userId, so the menu cannot bind directly to
/// it; instead the voice/speed `Binding`s in `ReaderPrefsMenuModel` read/write
/// these `@Observable` fields, and `SignedInView` persists each change back
/// through `TTSSettingsStore.save(_, userId:)`. Declared on every target so the
/// publisher modifier signature is uniform; only Catalyst consumes it.
@MainActor
@Observable
final class AudioMenuPrefs {
    var voice: String = TTSSettings.default.voice
    var speed: Double = TTSSettings.default.speed
    /// Guards the write-back so the initial async seed doesn't echo a save.
    var isSeeded: Bool = false
}

extension View {
    /// Publishes the `readerPrefsMenu` focused scene value on Mac Catalyst and
    /// seeds/persists the live audio holder; a no-op on iOS (which keeps the
    /// in-app gear + settings sheet).
    @ViewBuilder
    func readerPrefsMenuPublisher(
        services: BootstrappedServices,
        user: User,
        audioPrefs: AudioMenuPrefs,
        onSignedOut: @escaping () -> Void,
        account: MacAccountMenuModel?
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        self.modifier(
            ReaderPrefsMenuPublisher(services: services, user: user, audioPrefs: audioPrefs, onSignedOut: onSignedOut, account: account)
        )
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)

/// Catalyst-only modifier that builds + publishes the scene-scoped
/// `ReaderPrefsMenuModel` focused value (theme/font/pdf/voice/speed/sync) from
/// the post-bootstrap services and the live audio holder, AND pushes the
/// app-GLOBAL account/legal/auth payload into the focus-independent
/// `MacAccountMenuModel`. The account payload deliberately does NOT ride the
/// focused value: it resolved to nil when the menu bar opened (focus left the
/// content view), greyed out the Account submenu and showed "Not signed in"
/// while signed in. `userEmail` is resolved from the in-scope `user` (no async
/// `currentUser` call — Pitfall 3).
private struct ReaderPrefsMenuPublisher: ViewModifier {

    let services: BootstrappedServices
    let user: User
    @Bindable var audioPrefs: AudioMenuPrefs
    let onSignedOut: () -> Void
    let account: MacAccountMenuModel?

    init(services: BootstrappedServices, user: User, audioPrefs: AudioMenuPrefs, onSignedOut: @escaping () -> Void, account: MacAccountMenuModel?) {
        self.services = services
        self.user = user
        self.audioPrefs = audioPrefs
        self.onSignedOut = onSignedOut
        self.account = account
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.readerPrefsMenu, makeModel())
            .task(id: user.id) {
                let loaded = await services.ttsSettingsStore.load(userId: user.id)
                audioPrefs.voice = loaded.voice
                audioPrefs.speed = loaded.speed
                audioPrefs.isSeeded = true
            }
            // App-GLOBAL account payload: pushed into the focus-independent
            // model while the signed-in view is present, cleared on disappear
            // (sign-out / teardown) so the submenu disables itself.
            .onAppear { account?.update(makeAccountPayload()) }
            .onDisappear { account?.clear() }
    }

    private func makeModel() -> ReaderPrefsMenuModel {
        let defaults = services.readerDefaults
        return ReaderPrefsMenuModel(
            theme: Binding(
                get: { defaults.theme },
                set: { defaults.theme = $0 }
            ),
            pdfViewMode: Binding(
                get: { defaults.pdfViewMode },
                set: { defaults.pdfViewMode = $0 }
            ),
            fontFamily: Binding(
                get: { defaults.fontFamily },
                set: { defaults.fontFamily = $0 }
            ),
            voice: Binding(
                get: { audioPrefs.voice },
                set: { newValue in
                    audioPrefs.voice = newValue
                    persistAudio()
                }
            ),
            speed: Binding(
                get: { audioPrefs.speed },
                set: { newValue in
                    audioPrefs.speed = newValue
                    persistAudio()
                }
            ),
            autoSync: Binding(
                get: { defaults.autoSync },
                set: { defaults.autoSync = $0 }
            ),
            // KEEP: syncEngine.syncNow() is an actor await; mirrors
            // SettingsContent.swift:71. Manual sync ignores the autoSync flag.
            onSyncNow: { Task { await services.syncEngine.syncNow() } },
            syncStatus: services.syncStatus
        )
    }

    /// Build the app-GLOBAL account payload for `MacAccountMenuModel`. The
    /// account/legal/auth actions are app-level (not scene-scoped), so they live
    /// here rather than on the focused `ReaderPrefsMenuModel`. Each is routed to
    /// an existing service/URL with no custom window or sheet (§D). `userEmail`
    /// is resolved from the in-scope `user` (no async `currentUser` — Pitfall 3).
    private func makeAccountPayload() -> MacAccountMenuModel.Payload {
        MacAccountMenuModel.Payload(
            userEmail: user.email.isEmpty ? nil : user.email,
            // Manage Subscription drives StoreKit's system sheet via the
            // existing presenter (mirrors SettingsContent.swift:88-95);
            // explicit @MainActor matches that surface's isolation.
            onManageSubscription: {
                Task { @MainActor in
                    await services.manageSubscriptionPresenter.present()
                }
            },
            // Sign Out reuses the same auth flow + `onSignedOut` closure already
            // threaded into SettingsContent (flips the app back to signed-out).
            onSignOut: {
                let auth = services.authService
                let signedOut = onSignedOut
                Task { @MainActor in
                    try? await auth.signOut()
                    signedOut()
                }
            },
            // Privacy / Terms open the public LegalLinksSection.LegalLink URLs in
            // external Safari (no presenting surface needed from a menu command).
            onOpenPrivacy: { Self.open(LegalLinksSection.LegalLink.privacyPolicy) },
            onOpenTerms: { Self.open(LegalLinksSection.LegalLink.termsOfUse) }
        )
    }

    /// Open a legal link's canonical URL in external Safari. The `LegalLink`
    /// rawValue is the URL string; `UIApplication.open` needs no presenting
    /// view, which is why it suits a menu command (RESEARCH §D).
    private static func open(_ link: LegalLinksSection.LegalLink) {
        if let url = URL(string: link.rawValue) {
            UIApplication.shared.open(url)
        }
    }

    /// Persist the current voice/speed back through the store. Skips writes
    /// until the initial async seed completes so the seed itself never echoes
    /// a redundant save.
    private func persistAudio() {
        guard audioPrefs.isSeeded else { return }
        let settings = TTSSettings(voice: audioPrefs.voice, speed: audioPrefs.speed)
        let store = services.ttsSettingsStore
        let userId = user.id
        Task { await store.save(settings, userId: userId) }
    }
}

#endif

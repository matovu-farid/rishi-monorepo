import Foundation
import SwiftUI
import RishiSettings
import RishiOnboarding
import RishiAudio
import RishiSync
import RishiCore

// MARK: - Settings / onboarding / telemetry forwarder accessors

extension AppDependencies {
    var telemetryStore: any TelemetryStore { services!.telemetryStore }
    var footerDetectionStore: any FooterDetectionStore { services!.footerDetectionStore }
    var onboardingState: any OnboardingState { services!.onboardingState }
    var onboardingCoordinator: OnboardingCoordinator { services!.onboardingCoordinator }
    var readerDefaults: AppReaderDefaults { services!.readerDefaults }

    // MARK: - Settings factory (Phase 11)

    /// Builds the `RishiSettings.SettingsScreen` for the current user,
    /// wiring every dependency through.
    @MainActor
    func makeSettingsScreen(
        user: User,
        audioInitial: TTSSettings,
        onDismiss: @escaping () -> Void,
        onSignedOut: @escaping () -> Void,
        onAccountDeleted: @escaping () -> Void
    ) -> SettingsScreen {
        let defaults = self.readerDefaults
        let auth = self.authService
        let presenter = self.manageSubscriptionPresenter
        let sync = self.syncEngine
        return SettingsScreen(
            user: user,
            readerTheme: Binding(
                get: { defaults.theme },
                set: { defaults.theme = $0 }
            ),
            readerFontFamily: Binding(
                get: { defaults.fontFamily },
                set: { defaults.fontFamily = $0 }
            ),
            audioUserId: user.id,
            audioInitial: audioInitial,
            audioStore: ttsSettingsStore,
            onAudioChange: { _ in },
            syncStatus: syncStatus,
            // KEEP: Settings "Sync now" tap -> syncEngine actor await; no main IO.
            onSyncNow: { Task { await sync.syncNow() } },
            telemetryStore: telemetryStore,
            footerDetectionStore: footerDetectionStore,
            onSignOut: {
                try? await auth.signOut()
                await MainActor.run { onSignedOut() }
            },
            onDelete: {
                try await auth.deleteAccount()
            },
            onDeleted: onAccountDeleted,
            onManageSubscription: {
                // KEEP: presenter.present() drives StoreKit's
                // ManageSubscriptionsView which is a @MainActor sheet --
                // explicit isolation is required for the SwiftUI surface.
                Task { @MainActor in
                    await presenter.present()
                }
            },
            onDismiss: onDismiss
        )
    }
}

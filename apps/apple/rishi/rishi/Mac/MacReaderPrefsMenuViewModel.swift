//
//  MacReaderPrefsMenuViewModel.swift
//  rishi
//
//  Phase 34 Plan 34-09 (SRP) — extracted from the Catalyst
//  `ReaderPrefsMenuPublisher` ViewModifier that previously lived in
//  `SignedInView.swift`. The modifier was doing service work directly (auth
//  sign-out, StoreKit present, manual sync, TTS-settings persist) — a
//  view -> service layering inversion. This view-model now owns that logic so
//  the modifier only expresses UI intent (publish the focused value + push the
//  account payload), and the decision logic (seed-guarded write-back, payload
//  construction) is unit-testable without SwiftUI.
//
//  Catalyst-only: the whole type is gated; iOS keeps the in-app gear + settings
//  sheet untouched, so SignedInView declares no VM on iOS.
//

#if targetEnvironment(macCatalyst)

import SwiftUI
import RishiCore
import RishiAudio    // TTSSettings
import RishiReader   // ReaderTheme / ReaderFontFamily / PDFViewModeSetting
import RishiSettings // LegalLinksSection.LegalLink
import RishiSync     // SyncStatus
import RishiBilling  // ManageSubscriptionPresenter.present()
import RishiAuth     // RishiAuthService.signOut()
#if canImport(UIKit)
import UIKit
#endif

/// Owns the Mac reader-preference menu's service-calling logic, extracted out of
/// the `ReaderPrefsMenuPublisher` ViewModifier. The view-model holds the live
/// voice/speed holder (`AudioPrefs`), seeds it from the async TTS store, and
/// persists every change back — guarded so the initial seed never echoes a
/// redundant save. It also builds the scene-scoped `ReaderPrefsMenuModel` and
/// the app-global `MacAccountMenuModel.Payload`.
///
/// The service work is injected as plain closures so the VM is testable with
/// spies; `SignedInView` wires the live closures from the post-bootstrap
/// `BootstrappedServices` via the convenience initializer below (no
/// `AppDependencies` dependency — it uses only what the view already holds).
@MainActor
@Observable
final class MacReaderPrefsMenuViewModel {

    /// Live voice/speed selection for the menu checkmarks. `TTSSettings` is
    /// immutable + loaded async per userId, so the menu cannot bind to it
    /// directly; the `ReaderPrefsMenuModel` voice/speed bindings read/write
    /// THIS holder and the setters fan out through `persistAudio()`.
    @MainActor
    @Observable
    final class AudioPrefs {
        var voice: String = TTSSettings.default.voice
        var speed: Double = TTSSettings.default.speed
        /// Guards the write-back so the initial async seed doesn't echo a save.
        var isSeeded: Bool = false
    }

    let audioPrefs = AudioPrefs()

    // Reader-default bindings (theme/font/pdf/autoSync) — passed through 1:1.
    private let theme: Binding<ReaderTheme>
    private let pdfViewMode: Binding<PDFViewModeSetting>
    private let fontFamily: Binding<ReaderFontFamily>
    private let autoSync: Binding<Bool>
    private let syncStatus: SyncStatus

    // Injected service work (kept as closures so the VM unit-tests with spies).
    private let loadSettings: () async -> TTSSettings
    private let saveSettings: (TTSSettings) async -> Void
    private let runManualSync: () async -> Void
    private let presentManageSubscription: () async -> Void
    private let signOut: () async -> Void
    private let openURL: (URL) -> Void

    // Account payload inputs.
    private let userEmail: String?

    /// Designated initializer — pure closures, no service references. Used by
    /// tests with spies.
    init(
        theme: Binding<ReaderTheme>,
        pdfViewMode: Binding<PDFViewModeSetting>,
        fontFamily: Binding<ReaderFontFamily>,
        autoSync: Binding<Bool>,
        syncStatus: SyncStatus,
        userEmail: String?,
        loadSettings: @escaping () async -> TTSSettings,
        saveSettings: @escaping (TTSSettings) async -> Void,
        runManualSync: @escaping () async -> Void,
        presentManageSubscription: @escaping () async -> Void,
        signOut: @escaping () async -> Void,
        openURL: @escaping (URL) -> Void
    ) {
        self.theme = theme
        self.pdfViewMode = pdfViewMode
        self.fontFamily = fontFamily
        self.autoSync = autoSync
        self.syncStatus = syncStatus
        self.userEmail = userEmail
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
        self.runManualSync = runManualSync
        self.presentManageSubscription = presentManageSubscription
        self.signOut = signOut
        self.openURL = openURL
    }

    // MARK: - Seed / persist

    /// Seed the live voice/speed holder from the async TTS store and arm
    /// write-back. Called from the publisher's `.task(id:)`. Equivalent to the
    /// former modifier `.task` body.
    func seed() async {
        let loaded = await loadSettings()
        audioPrefs.voice = loaded.voice
        audioPrefs.speed = loaded.speed
        audioPrefs.isSeeded = true
    }

    /// Persist the current voice/speed back through the store. Skips writes
    /// until the initial async seed completes so the seed itself never echoes a
    /// redundant save. (The seed-guard decision is the unit-tested core.)
    func persistAudio() {
        guard audioPrefs.isSeeded else { return }
        let settings = TTSSettings(voice: audioPrefs.voice, speed: audioPrefs.speed)
        Task { await saveSettings(settings) }
    }

    // MARK: - Menu payloads

    /// Build the scene-scoped reader-preference menu model. The voice/speed
    /// bindings read/write the live holder and persist on every change; the
    /// reader-default bindings pass through. Manual "Sync Now" ignores the
    /// `autoSync` flag (mirrors `SettingsContent`).
    func makeModel() -> ReaderPrefsMenuModel {
        ReaderPrefsMenuModel(
            theme: theme,
            pdfViewMode: pdfViewMode,
            fontFamily: fontFamily,
            voice: Binding(
                get: { self.audioPrefs.voice },
                set: { newValue in
                    self.audioPrefs.voice = newValue
                    self.persistAudio()
                }
            ),
            speed: Binding(
                get: { self.audioPrefs.speed },
                set: { newValue in
                    self.audioPrefs.speed = newValue
                    self.persistAudio()
                }
            ),
            autoSync: autoSync,
            onSyncNow: { [runManualSync] in Task { await runManualSync() } },
            syncStatus: syncStatus
        )
    }

    /// Build the app-GLOBAL account payload for `MacAccountMenuModel`. Each
    /// action routes to the injected service closure. `userEmail` is the
    /// in-scope user's address (empty -> nil so the menu falls back to the
    /// disabled "Not signed in" line).
    func makeAccountPayload() -> MacAccountMenuModel.Payload {
        MacAccountMenuModel.Payload(
            userEmail: (userEmail?.isEmpty == false) ? userEmail : nil,
            onManageSubscription: { [presentManageSubscription] in
                Task { @MainActor in await presentManageSubscription() }
            },
            onSignOut: { [signOut] in
                Task { @MainActor in await signOut() }
            },
            onOpenPrivacy: { self.open(.privacyPolicy) },
            onOpenTerms: { self.open(.termsOfUse) }
        )
    }

    private func open(_ link: LegalLinksSection.LegalLink) {
        if let url = URL(string: link.rawValue) {
            openURL(url)
        }
    }
}

// MARK: - Wiring from the live service graph

extension MacReaderPrefsMenuViewModel {

    /// Convenience initializer that wires the service closures from the
    /// post-bootstrap `BootstrappedServices` + the in-scope `user`. Used by
    /// `SignedInView`'s Catalyst publisher; mirrors the behaviour of the former
    /// inline modifier 1:1 (no `AppDependencies` dependency — only what the
    /// view already holds).
    convenience init(
        services: BootstrappedServices,
        user: User,
        onSignedOut: @escaping () -> Void
    ) {
        let defaults = services.readerDefaults
        let store = services.ttsSettingsStore
        let syncEngine = services.syncEngine
        let presenter = services.manageSubscriptionPresenter
        let auth = services.authService
        let userId = user.id
        self.init(
            theme: Binding(get: { defaults.theme }, set: { defaults.theme = $0 }),
            pdfViewMode: Binding(get: { defaults.pdfViewMode }, set: { defaults.pdfViewMode = $0 }),
            fontFamily: Binding(get: { defaults.fontFamily }, set: { defaults.fontFamily = $0 }),
            autoSync: Binding(get: { defaults.autoSync }, set: { defaults.autoSync = $0 }),
            syncStatus: services.syncStatus,
            userEmail: user.email,
            loadSettings: { await store.load(userId: userId) },
            saveSettings: { settings in await store.save(settings, userId: userId) },
            // KEEP: syncEngine.syncNow() is an actor await; mirrors
            // SettingsContent.swift:71. Manual sync ignores the autoSync flag.
            runManualSync: { await syncEngine.syncNow() },
            // Manage Subscription drives StoreKit's system sheet via the
            // existing presenter (mirrors SettingsContent.swift:88-95).
            presentManageSubscription: { await presenter.present() },
            // Sign Out reuses the same auth flow + `onSignedOut` closure already
            // threaded into SettingsContent (flips the app back to signed-out).
            signOut: {
                try? await auth.signOut()
                onSignedOut()
            },
            // Privacy / Terms open the public LegalLink URLs in external Safari
            // (no presenting surface needed from a menu command).
            openURL: { url in UIApplication.shared.open(url) }
        )
    }
}

#endif

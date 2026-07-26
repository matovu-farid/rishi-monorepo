

#if targetEnvironment(macCatalyst)

import SwiftUI







#if canImport(UIKit)
import UIKit
#endif


@MainActor
@Observable
final class MacReaderPrefsMenuViewModel {


    @MainActor
    @Observable
    final class AudioPrefs {
        var voice: String = TTSSettings.default.voice
        var speed: Double = TTSSettings.default.speed
        
        var isSeeded: Bool = false
    }

    let audioPrefs = AudioPrefs()

    
    private let theme: Binding<ReaderTheme>
    private let pdfViewMode: Binding<PDFViewModeSetting>
    private let fontFamily: Binding<ReaderFontFamily>
    private let autoSync: Binding<Bool>
    private let syncStatus: SyncStatus

    
    private let loadSettings: () async -> TTSSettings
    private let saveSettings: (TTSSettings) async -> Void
    private let runManualSync: () async -> Void
    private let presentManageSubscription: () async -> Void
    private let signOut: () async -> Void
    private let openURL: (URL) -> Void

    
    private let userEmail: String?


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

    

  
    func seed() async {
        let loaded = await loadSettings()
        audioPrefs.voice = loaded.voice
        audioPrefs.speed = loaded.speed
        audioPrefs.isSeeded = true
    }


    func persistAudio() {
        guard audioPrefs.isSeeded else { return }
        let settings = TTSSettings(
            voice: audioPrefs.voice,
            model: TTSSettings.default.model,
            speed: audioPrefs.speed
        )
        Task { await saveSettings(settings) }
    }

    


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



extension MacReaderPrefsMenuViewModel {


    convenience init(
        services: BootstrappedServices,
        user: User,
        onSignedOut: @escaping () -> Void
    ) {
        let defaults = services.readerDefaults
        let store = services.ttsSettingsStore
        let syncEngine = services.syncEngine
        let presenter = services.manageSubscriptionPresenter
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
            
            
            runManualSync: { await syncEngine.syncNow() },
            
            
            presentManageSubscription: { await presenter.present() },
            
            
            signOut: {
                onSignedOut()
            },
            
            
            openURL: { url in UIApplication.shared.open(url) }
        )
    }
}

#endif

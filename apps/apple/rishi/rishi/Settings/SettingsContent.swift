



















import SwiftUI
import RishiAudio
import RishiAuth
import RishiBilling
import RishiCore
import RishiSettings
import RishiSync




struct SettingsContent: View {

    let services: BootstrappedServices
    let user: User
    
    
    let onDismiss: () -> Void

    
    
    
    @Environment(\.signOut) private var signOut

    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false

    var body: some View {
        Group {
            if audioLoaded {
                let defaults = services.readerDefaults
                let auth = services.authService
                let presenter = services.manageSubscriptionPresenter
                let sync = services.syncEngine
                SettingsScreen(
                    user: user,
                    readerTheme: Binding(
                        get: { defaults.theme },
                        set: { defaults.theme = $0 }
                    ),
                    readerFontFamily: Binding(
                        get: { defaults.fontFamily },
                        set: { defaults.fontFamily = $0 }
                    ),
                    pdfViewMode: Binding(
                        get: { defaults.pdfViewMode },
                        set: { defaults.pdfViewMode = $0 }
                    ),
                    audioUserId: user.id,
                    audioInitial: initialAudio,
                    audioStore: services.ttsSettingsStore,
                    onAudioChange: { _ in },
                    syncStatus: services.syncStatus,
                    
                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: services.telemetryStore,
                    footerDetectionStore: services.footerDetectionStore,
                    onSignOut: {
                        try? await auth.signOut()
                        await MainActor.run {
                            onDismiss()
                            signOut()
                        }
                    },
                    onDelete: {
                        try await auth.deleteAccount()
                    },
                    onDeleted: {
                        onDismiss()
                        signOut()
                    },
                    onManageSubscription: {
                        
                        
                        
                        Task { @MainActor in
                            await presenter.present()
                        }
                    },
                    onDismiss: { onDismiss() }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            
            
            
            initialAudio = await services.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
    }
}

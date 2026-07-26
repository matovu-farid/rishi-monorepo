





import SwiftUI

struct SettingsContent: View {

    let services: BootstrappedServices
    let user: User

    let onDismiss: () -> Void

    @Environment(\.signOut) private var signOut
    @Environment(CurrentUserBox.self) private var currentUserBox
    @Environment(EntitlementSnapshotStore.self) private var entitlementStore

    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false
    @State private var showSubscriptions = false

    var body: some View {
        Group {
            if audioLoaded {
                let defaults = services.readerDefaults
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
                    voiceLanguage: Binding(
                        get: { defaults.voiceLanguage },
                        set: { defaults.voiceLanguage = $0 }
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
                    entitlementSnapshot: entitlementStore.resolvedSnapshot,
                    allowanceLoading: entitlementStore.isLoading,
                    onSubscribe: { showSubscriptions = true },
                    onSignOut: {
                        await MainActor.run {
                            onDismiss()
                            signOut()
                        }
                    },
                    onDelete: {
                        await MainActor.run {
                            onDismiss()
                            signOut()
                        }
                    },
                    onDeleted: {
                        onDismiss()
                        signOut()
                    },

                    onDismiss: { onDismiss() }
                )
            } else {
#if DEBUG
                Text("AudioLoaded not loaded")
#endif
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {

            initialAudio = await services.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
        .sheet(isPresented: $showSubscriptions, onDismiss: {
            Task {
                await services.entitlementRefreshCoordinator.refreshIfSignedIn(
                    reason: .foreground
                )
            }
        }) {
            if let groupID = services.groupID {
                SubscriptionsView(groupID: groupID.value)
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "Plans unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load subscription plans. Try again later.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSubscriptions = false }
                        }
                    }
                }
            }
        }
    }
}

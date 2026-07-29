





import SwiftUI

struct SettingsContent: View {

    let services: BootstrappedServices
    let user: User

    let onDismiss: () -> Void

    @Environment(\.signOut) private var signOut
    @Environment(CurrentUserBox.self) private var currentUserBox
    @Environment(EntitlementSnapshotStore.self) private var entitlementStore
    @State private var customerEntitlements = CustomerEntitlements.shared

    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false
    @State private var showSubscriptions = false
    @State private var pendingSubscriptionConfirmation = false
    @State private var showSubscriptionConfirmation = false

    private var hasActiveStoreKitSubscription: Bool {
        guard let groupID = services.billing.groupID?.value else { return false }
        return customerEntitlements.hasActiveSubscription(in: groupID)
    }

    var body: some View {
        Group {
            if audioLoaded {
                let defaults = services.settings.readerDefaults
                let sync = services.sync.engine
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
                    audioStore: services.audio.ttsSettingsStore,
                    onAudioChange: { _ in },
                    syncStatus: services.sync.status,

                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: services.settings.telemetryStore,
                    footerDetectionStore: services.settings.footerDetectionStore,
                    entitlementSnapshot: entitlementStore.resolvedSnapshot,
                    allowanceLoading: entitlementStore.isLoading,
                    onSubscribe: { showSubscriptions = true },
                    storeKitIsSubscribed: hasActiveStoreKitSubscription,
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

            initialAudio = await services.audio.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
        .sheet(isPresented: $showSubscriptions, onDismiss: {
            Task {
                await services.billing.entitlementRefreshCoordinator.refreshIfSignedIn(
                    reason: .foreground
                )
                guard pendingSubscriptionConfirmation else { return }
                await MainActor.run {
                    pendingSubscriptionConfirmation = false
                    showSubscriptionConfirmation = true
                }
            }
        }) {
            if services.billing.groupID != nil {
                SubscriptionsView(
                    dependencies: SubscriptionDependencies(
                        groupID: services.billing.groupID,
                        entitlementRefreshCoordinator: services.billing.entitlementRefreshCoordinator,
                        restoreService: services.billing.restoreService
                    ),
                    onPurchaseCompleted: {
                    pendingSubscriptionConfirmation = true
                    showSubscriptions = false
                })
                .environment(services.billing.entitlementSnapshotStore)
                .environment(services.billing.manageSubscriptionPresenter)
                .environment(Store.shared)
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
        .alert("Subscription active", isPresented: $showSubscriptionConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thank you for subscribing. Your plan is now active.")
        }
    }
}

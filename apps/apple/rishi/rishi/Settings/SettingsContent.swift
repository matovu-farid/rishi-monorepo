





import SwiftUI

struct SettingsContentDependencies {
    let workerClient: WorkerClient
    let readerDefaults: AppReaderDefaults
    let ttsSettingsStore: any TTSSettingsStore
    let syncStatus: SyncStatus
    let syncEngine: SyncEngine
    let telemetryStore: any TelemetryStore
    let footerDetectionStore: any FooterDetectionStore
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let restoreService: RestoreService
    let manageSubscriptionPresenter: ManageSubscriptionPresenter
    let groupID: GroupId?
    let dataUseConsentStore: any DataUseConsentStore
    let onRevokeDataUse: @Sendable () async -> Void
    let deleteAccount: @Sendable (UUID) async throws -> Void
}

struct SettingsContent: View {

    let dependencies: SettingsContentDependencies
    let user: User

    let onDismiss: () -> Void

    @Environment(\.signOut) private var signOut
    @Environment(CurrentUserBox.self) private var currentUserBox
    @State private var displayedUser: User
    @State private var customerEntitlements = CustomerEntitlements.shared

    @State private var initialAudio: TTSSettings = .default
    @State private var audioLoaded = false
    @State private var showSubscriptions = false
    @State private var pendingSubscriptionConfirmation = false
    @State private var showSubscriptionConfirmation = false
    @State private var showUsernameEditor = false

    init(
        dependencies: SettingsContentDependencies,
        user: User,
        onDismiss: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.user = user
        self.onDismiss = onDismiss
        _displayedUser = State(initialValue: user)
    }

    private var hasActiveStoreKitSubscription: Bool {
        guard let groupID = dependencies.groupID?.value else { return false }
        return customerEntitlements.hasActiveSubscription(in: groupID)
    }

    var body: some View {
        Group {
            if audioLoaded {
                let defaults = dependencies.readerDefaults
                let sync = dependencies.syncEngine
                SettingsScreen(
                    user: displayedUser,
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
                    audioStore: dependencies.ttsSettingsStore,
                    onAudioChange: { _ in },
                    syncStatus: dependencies.syncStatus,

                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: dependencies.telemetryStore,
                    footerDetectionStore: dependencies.footerDetectionStore,
                    entitlementSnapshot: dependencies.entitlementSnapshotStore.resolvedSnapshot,
                    allowanceLoading: dependencies.entitlementSnapshotStore.isLoading,
                    onSubscribe: { showSubscriptions = true },
                    storeKitIsSubscribed: hasActiveStoreKitSubscription,
                    dataUseConsentStore: dependencies.dataUseConsentStore,
                    onRevokeDataUse: dependencies.onRevokeDataUse,
                    onEditUsername: { showUsernameEditor = true },
                    onSignOut: {
                        await MainActor.run {
                            onDismiss()
                            signOut()
                        }
                    },
                    onDelete: {
                        try await dependencies.deleteAccount(user.id)
                    },
                    onDeleted: {
                        onDismiss()
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
        .sheet(isPresented: $showUsernameEditor) {
            UsernameEditorView(username: displayedUser.username) { username in
                let updated = try await dependencies.workerClient.send(
                    UserUpdateEndpoint(username: username)
                )
                await MainActor.run {
                    displayedUser = updated
                    currentUserBox.signIn(user: updated)
                }
                return updated
            }
        }
        .task {

            initialAudio = await dependencies.ttsSettingsStore.load(userId: user.id)
            audioLoaded = true
        }
        .rishiSubscriptionPresentation(isPresented: $showSubscriptions, onDismiss: {
            Task {
            await dependencies.entitlementRefreshCoordinator.refreshIfSignedIn(
                    reason: .foreground
                )
                guard pendingSubscriptionConfirmation else { return }
                await MainActor.run {
                    pendingSubscriptionConfirmation = false
                    showSubscriptionConfirmation = true
                }
            }
        }) {
            if dependencies.groupID != nil {
                SubscriptionsView(
                    dependencies: SubscriptionDependencies(
                        groupID: dependencies.groupID,
                        entitlementRefreshCoordinator: dependencies.entitlementRefreshCoordinator,
                        restoreService: dependencies.restoreService
                    ),
                    onPurchaseCompleted: {
                    pendingSubscriptionConfirmation = true
                    showSubscriptions = false
                })
                .environment(dependencies.entitlementSnapshotStore)
                .environment(dependencies.manageSubscriptionPresenter)
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

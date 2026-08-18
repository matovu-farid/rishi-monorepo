







import SwiftUI
import StoreKit

struct LibraryTabDependencies {
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let readerDefaults: AppReaderDefaults
    let syncEngine: SyncEngine
    let sharePackageService: SharePackageService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let groupID: GroupId?
    let settings: SettingsContentDependencies
}

struct LibrarySyncCompletionRefreshObserver {
    private let refresh: () async -> Void

    init(refresh: @escaping () async -> Void) {
        self.refresh = refresh
    }

    func statusChanged(from wasRunning: Bool?, to status: SyncStatusSnapshot) async {
        guard wasRunning == true, !status.isRunning else { return }
        await refresh()
    }
}

struct LibraryTabView: View {

    let dependencies: LibraryTabDependencies
    let user: User
    let model: SignedInViewModel
    let dataUseConsentGranted: Bool
    let onLibraryReadyForTrial: () -> Void

    @Environment(AppRouter.self) private var router
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif
    @State private var vm: LibraryViewModel
    @State private var hasSeenFirstBookPrompt = false
    @State private var showFirstBookPrompt = false
    @State private var showDocumentPicker = false
    @State private var presentDocumentPickerAfterPrompt = false
    @State private var pendingFirstPromptImport = false
    @State private var trialReadyAfterDocumentPicker = false
    @State private var pendingSubscriptionConfirmation = false
    @State private var showSubscriptionConfirmation = false

    private var firstBookPromptSeenKey: String {
        "rishi.library.firstBookPrompt.seen.\(user.id.uuidString)"
    }

    private func markFirstBookPromptSeen() {
        hasSeenFirstBookPrompt = true
        UserDefaults.standard.set(true, forKey: firstBookPromptSeenKey)
    }

    init(
        dependencies: LibraryTabDependencies,
        user: User,
        model: SignedInViewModel,
        dataUseConsentGranted: Bool = false,
        onLibraryReadyForTrial: @escaping () -> Void = {},
    ) {
        self.dependencies = dependencies
        self.user = user
        self.model = model
        self.dataUseConsentGranted = dataUseConsentGranted
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
        _vm = State(initialValue: LibraryViewModel.make(
            bookStore: dependencies.bookStore,
            userId: user.id,
            importCoordinator: dependencies.importCoordinator,
            positionStore: dependencies.positionStore,
            bookFileStorage: dependencies.bookFileStorage,
            onBookDeleted: { bookId in
                try await dependencies.syncEngine.markBookDeleted(bookId)
            }
        ))
    }

    private var settingsHandler: (() -> Void) {

        return { model.requestSettings() }
    }

    @MainActor
    private func refreshAfterSyncCompletion() async {
        await vm.refresh()
        await dependencies.sharePackageService.prewarm(bookIDs: vm.books.map(\.id))
    }

    @MainActor
    private func openBook(_ book: Book) {
        model.hint(book)
        #if targetEnvironment(macCatalyst)
            readerWindows.open(book: book, user: user)
        #else
            router.path.append(ReaderRoute.route(for: book))
        #endif
    }

    @MainActor
    private func handleImported(_ outcomes: [ImportCoordinator.ImportOutcome]) {
        let cameFromFirstPrompt = pendingFirstPromptImport
        pendingFirstPromptImport = false
        let successes = outcomes.compactMap(\.book)
        if !successes.isEmpty {
            markFirstBookPromptSeen()
        }
        if cameFromFirstPrompt,
           let book = successes.first(where: { book in
               book.formatType == .epub || book.formatType == .pdf
           }) {
            router.requestReaderTour(for: book.id, userID: user.id)
            openBook(book)
            return
        }
        guard successes.count == 1, let book = successes.first
        else { return }
        openBook(book)
    }

    var body: some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
          
                path: bindableRouter.path,
                importCoordinator: dependencies.importCoordinator,
                onOpenBook: openBook,
                onShowSettings: settingsHandler,
                onImported: handleImported,
                documentPickerPresented: $showDocumentPicker,
                sharePackageService: dependencies.sharePackageService
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(
                    route: route,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { name in
                        let paid = dependencies.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                        model.requestPaywall(name, serverPaidActive: paid)
                    }
                )
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                ConversationsListHost(
                    vm: ConversationsListViewModel.make(
                        conversationStore: dependencies.conversationStore,
                        messageStore: dependencies.messageStore
                    ),
                    userId: user.id,
                    onSelect: { convo in model.present(conversation: convo) }
                )
            }
            .task {
         
                for await result in Transaction.currentEntitlements {
                    guard case .verified(let transaction) = result else {
                        
                        continue
                    }
                    let _ = try? await VerifyEndPont(body: .init(transactionId: transaction.id)).send()
                    
                    
                    
                    
                }
            }
            
            .task(id: "\(user.id.uuidString)-\(dataUseConsentGranted)") {
                hasSeenFirstBookPrompt = UserDefaults.standard.bool(forKey: firstBookPromptSeenKey)
                await model.performInitialLibrarySyncIfConsented(
                    consentGranted: dataUseConsentGranted,
                    refresh: { await vm.refresh() },
                    sync: {
                        if dependencies.readerDefaults.autoSync {
                            _ = await dependencies.syncEngine.runOnce()
                        }
                    }
                )

                if !hasSeenFirstBookPrompt && vm.books.isEmpty {
                    showFirstBookPrompt = true
                    return
                }
                if !hasSeenFirstBookPrompt {
                    // A restored/synced library already has content, so this
                    // device no longer needs the first-book invitation.
                    markFirstBookPromptSeen()
                }

                // No first-book sheet is competing with the trial notice.
                onLibraryReadyForTrial()

            }
            .onChange(of: dependencies.settings.syncStatus.isRunning) { wasRunning, isRunning in
                guard wasRunning, !isRunning else { return }
                Task { await refreshAfterSyncCompletion() }
            }
        }
        .environment(vm)

        .sheet(isPresented: $showFirstBookPrompt, onDismiss: {
            let shouldPresentPicker = presentDocumentPickerAfterPrompt
            presentDocumentPickerAfterPrompt = false
            Task { @MainActor in
                if shouldPresentPicker {
                    trialReadyAfterDocumentPicker = true
                    showDocumentPicker = true
                } else {
                    onLibraryReadyForTrial()
                }
            }
        }) {
            SampleOrImportScreen(
                onUseSample: {
                    pendingFirstPromptImport = false
                    markFirstBookPromptSeen()
                    showFirstBookPrompt = false
                    Task {
                        _ = await dependencies.sampleBookInstaller.installIfNeeded(
                            ownerId: user.id
                        )
                        await vm.refresh()
                        await installSampleReaderIfNeeded()
                    }
                },
                onImport: {
                    pendingFirstPromptImport = true
                    presentDocumentPickerAfterPrompt = true
                    showFirstBookPrompt = false
                },
                onSkip: {
                    pendingFirstPromptImport = false
                    markFirstBookPromptSeen()
                    showFirstBookPrompt = false
                }
            )
        }
        .onChange(of: showDocumentPicker) { _, isPresented in
            guard !isPresented, trialReadyAfterDocumentPicker else { return }
            trialReadyAfterDocumentPicker = false
            onLibraryReadyForTrial()
        }

        #if !targetEnvironment(macCatalyst)
            .sheet(isPresented: Bindable(model).showSettings) {
                SettingsSheet(
                    dependencies: SettingsContentDependencies(
                        workerClient: dependencies.settings.workerClient,
                        readerDefaults: dependencies.settings.readerDefaults,
                        ttsSettingsStore: dependencies.settings.ttsSettingsStore,
                        syncStatus: dependencies.settings.syncStatus,
                        syncEngine: dependencies.settings.syncEngine,
                        telemetryStore: dependencies.settings.telemetryStore,
                        footerDetectionStore: dependencies.settings.footerDetectionStore,
                        entitlementSnapshotStore: dependencies.settings.entitlementSnapshotStore,
                        entitlementRefreshCoordinator: dependencies.settings.entitlementRefreshCoordinator,
                        restoreService: dependencies.settings.restoreService,
                        manageSubscriptionPresenter: dependencies.settings.manageSubscriptionPresenter,
                        groupID: dependencies.settings.groupID,
                    dataUseConsentStore: dependencies.settings.dataUseConsentStore,
                    onRevokeDataUse: {},
                    deleteAccount: dependencies.settings.deleteAccount
                    ),
                    user: user
                )
            }
        #endif

        .rishiSubscriptionPresentation(item: Bindable(model).paywallFeature, onDismiss: {
            // Best-effort: purchase/restore via SubscriptionStoreView may have
            // synced entitlements while the sheet was up.
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
        }) { _ in
            if dependencies.groupID != nil {
                SubscriptionsView(
                    dependencies: SubscriptionDependencies(
                        groupID: dependencies.groupID,
                        entitlementRefreshCoordinator: dependencies.entitlementRefreshCoordinator,
                        restoreService: dependencies.settings.restoreService
                    ),
                    onPurchaseCompleted: {
                    pendingSubscriptionConfirmation = true
                    model.dismissPaywall()
                })
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "Plans unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load subscription plans. Try again later.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { model.dismissPaywall() }
                        }
                    }
                }
            }
        }
        .onChange(of: dependencies.entitlementSnapshotStore.resolution) { old, new in
            let oldPaid = old.resolvedSnapshot?.isPaidActive ?? false
            let newPaid = new.resolvedSnapshot?.isPaidActive ?? false
            // Dismiss only when crossing into paid-active (verified grant).
            // Do not dismiss when already paid (allowance upgrade / plan change).
            if model.paywallFeature != nil, newPaid, !oldPaid {
                model.dismissPaywall()
            }
        }
        .onChange(of: model.paywallFeature) { old, new in
            guard old != nil, new == nil, pendingSubscriptionConfirmation else { return }
            pendingSubscriptionConfirmation = false
            showSubscriptionConfirmation = true
        }
        .alert("Subscription active", isPresented: $showSubscriptionConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thank you for subscribing. Your plan is now active.")
        }

        .deepLinkHandling(
            model: model,
            refreshLibrary: { await vm.refresh() },
            currentUserID: user.id
        )
    }

    @MainActor
    private func installSampleReaderIfNeeded() async {
        _ = await dependencies.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
        await vm.refresh()
    }
}

@MainActor
private struct LibraryTabPreviewHost: View {
    private let user = User(
        id: LibraryRootPreviewFixtures.userId,
        email: "reader@example.com",
        name: "Preview Reader"
    )
    @State private var vm = LibraryRootPreviewFixtures.makeViewModel(
        books: LibraryRootPreviewFixtures.populated
    )

    var body: some View {
        NavigationStack {
            LibraryRootView(
                importCoordinator: LibraryRootPreviewFixtures.makeImportCoordinator(),
                onOpenBook: { _ in },
                onShowSettings: {},
                documentPickerPresented: nil
            )
        }
        .environment(vm)
    }
}

#Preview("Library tab — populated") {
    LibraryTabPreviewHost()
}

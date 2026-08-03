







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
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let groupID: GroupId?
    let settings: SettingsContentDependencies
}

struct LibraryTabView: View {

    let dependencies: LibraryTabDependencies
    let user: User
    let model: SignedInViewModel
    let onLibraryReadyForTrial: () -> Void

    @Environment(AppRouter.self) private var router
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif
    @State private var vm: LibraryViewModel
    @AppStorage("rishi.library.firstBookPrompt.seen") private var hasSeenFirstBookPrompt = false
    @State private var showFirstBookPrompt = false
    @State private var showDocumentPicker = false
    @State private var presentDocumentPickerAfterPrompt = false
    @State private var trialReadyAfterDocumentPicker = false
    @State private var pendingSubscriptionConfirmation = false
    @State private var showSubscriptionConfirmation = false

    init(
        dependencies: LibraryTabDependencies,
        user: User,
        model: SignedInViewModel,
        onLibraryReadyForTrial: @escaping () -> Void = {},
    ) {
        self.dependencies = dependencies
        self.user = user
        self.model = model
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
        _vm = State(initialValue: LibraryViewModel.make(
            bookStore: dependencies.bookStore,
            userId: user.id,
            importCoordinator: dependencies.importCoordinator,
            positionStore: dependencies.positionStore,
            bookFileStorage: dependencies.bookFileStorage,
            onBookDeleted: { bookId in
                await dependencies.syncEngine.markBookDeleted(bookId)
            }
        ))
    }

    private var settingsHandler: (() -> Void) {

        return { model.requestSettings() }
    }

    var body: some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
          
                path: bindableRouter.path,
                importCoordinator: dependencies.importCoordinator,
                onOpenBook: { book in
                    model.hint(book)
                    #if targetEnvironment(macCatalyst)
                        readerWindows.open(book: book, user: user)
                    #else
                        router.path.append(ReaderRoute.route(for: book))
                    #endif
                },
                onShowSettings: settingsHandler,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    if !successes.isEmpty {
                        hasSeenFirstBookPrompt = true
                    }
                    guard successes.count == 1, let book = successes.first
                    else { return }
                    model.hint(book)
                    #if targetEnvironment(macCatalyst)
                        readerWindows.open(book: book, user: user)
                    #else
                        router.path.append(ReaderRoute.route(for: book))
                    #endif
                },
                documentPickerPresented: $showDocumentPicker
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
            
            .task(id: user.id) {
                await model.performInitialLibrarySync(
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
                    hasSeenFirstBookPrompt = true
                }

                // No first-book sheet is competing with the trial notice.
                onLibraryReadyForTrial()

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
                    hasSeenFirstBookPrompt = true
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
                    presentDocumentPickerAfterPrompt = true
                    showFirstBookPrompt = false
                },
                onSkip: {
                    hasSeenFirstBookPrompt = true
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

        .sheet(item: Bindable(model).paywallFeature, onDismiss: {
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

        .deepLinkHandling(model: model, refreshLibrary: { await vm.refresh() })
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

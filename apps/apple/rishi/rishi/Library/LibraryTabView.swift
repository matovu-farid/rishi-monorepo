







import SwiftUI
import StoreKit

struct LibraryTabView: View {

    let services: BootstrappedServices
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
        services: BootstrappedServices,
        user: User,
        model: SignedInViewModel,
        onLibraryReadyForTrial: @escaping () -> Void = {},
    ) {
        self.services = services
        self.user = user
        self.model = model
        self.onLibraryReadyForTrial = onLibraryReadyForTrial
        _vm = State(initialValue: LibraryViewModel.make(services: services, user: user))
    }

    private var settingsHandler: (() -> Void) {

        return { model.requestSettings() }
    }

    var body: some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
          
                path: bindableRouter.path,
                importCoordinator: services.library.importCoordinator,
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
                        let paid = services.billing.entitlementSnapshotStore.resolvedSnapshot?.isPaidActive ?? false
                        model.requestPaywall(name, serverPaidActive: paid)
                    }
                )
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                ConversationsListHost(
                    vm: ConversationsListViewModel.make(services: services),
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
                        if services.settings.readerDefaults.autoSync {
                            _ = await services.sync.engine.runOnce()
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
                        _ = await services.library.sampleBookInstaller.installIfNeeded(
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
                    services: services,
                    user: user
                )
            }
        #endif

        .sheet(item: Bindable(model).paywallFeature, onDismiss: {
            // Best-effort: purchase/restore via SubscriptionStoreView may have
            // synced entitlements while the sheet was up.
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
        }) { _ in
            if services.billing.groupID != nil {
                SubscriptionsView(onPurchaseCompleted: {
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
        .onChange(of: services.billing.entitlementSnapshotStore.resolution) { old, new in
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
        _ = await services.library.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
        await vm.refresh()
    }
}

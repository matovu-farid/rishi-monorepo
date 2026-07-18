import RishiBilling
import RishiChat
import RishiCore
import RishiLibrary
import RishiReader
import RishiSettings
import RishiSync
import SwiftUI
import StoreKit

struct LibraryTabView: View {

    let services: BootstrappedServices
    let user: User
    let model: SignedInViewModel

    @Environment(AppRouter.self) private var router
    @State private var vm: LibraryViewModel

    init(
        services: BootstrappedServices,
        user: User,
        model: SignedInViewModel,
    ) {
        self.services = services
        self.user = user
        self.model = model
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
                importCoordinator: services.importCoordinator,
                onOpenBook: { book in
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                },

                onShowSettings: settingsHandler,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first
                    else { return }
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(
                    route: route,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { model.requestPaywall($0) }
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
                async let sample = services.sampleBookInstaller.installIfNeeded(
                    ownerId: user.id
                )
                async let reader = services.sampleReaderInstaller
                    .installIfNeeded(ownerId: user.id)
                _ = await (sample, reader)

                await model.performInitialLibrarySync(
                    refresh: { await vm.refresh() },
                    sync: {
                        if services.readerDefaults.autoSync {
                            _ = await services.syncEngine.runOnce()
                        }
                    }
                )
            }
        }
        .environment(vm)

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
            Task { await services.entitlementService.refreshSnapshot() }
        }) { _ in
            if let groupId = services.groupID {
                SubscriptionsView(color: .systemBlue, groupId: groupId)
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
        
        .deepLinkHandling(model: model, refreshLibrary: { await vm.refresh() })
    }
}

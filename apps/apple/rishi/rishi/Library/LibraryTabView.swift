//
//  LibraryTabView.swift
//  rishi
//
//  Owns LibraryViewModel and renders the library NavigationStack, including
//  reader/conversations destinations, the settings sheet, and the deep-link
//  onOpenURL handler (which needs libraryVM for post-import refresh).
//

import SwiftUI
import RishiCore
import RishiLibrary
import RishiChat
import RishiReader
import RishiSettings

struct LibraryTabView: View {

    let services: BootstrappedServices
    let user: User
    let model: SignedInViewModel
    let onCacheUserId: (UserID) -> Void
    let onShowChats: () -> Void
    let onSignedOut: () -> Void

    @Environment(AppRouter.self) private var router

    @State private var libraryVM: LibraryViewModel

    init(
        services: BootstrappedServices,
        user: User,
        model: SignedInViewModel,
        onCacheUserId: @escaping (UserID) -> Void,
        onShowChats: @escaping () -> Void,
        onSignedOut: @escaping () -> Void
    ) {
        self.services = services
        self.user = user
        self.model = model
        self.onCacheUserId = onCacheUserId
        self.onShowChats = onShowChats
        self.onSignedOut = onSignedOut
        _libraryVM = State(initialValue: LibraryViewModel.make(services: services, user: user))
    }

    var body: some View {
        let bindableRouter = Bindable(router)
        NavigationStack(path: bindableRouter.path) {
            LibraryRootView(
                viewModel: libraryVM,
                path: bindableRouter.path,
                importCoordinator: services.importCoordinator,
                onOpenBook: { book in
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                },
                onShowSettings: { model.requestSettings() },
                onShowChats: onShowChats,
                onImported: { outcomes in
                    let successes = outcomes.compactMap(\.book)
                    guard successes.count == 1, let book = successes.first else { return }
                    model.hint(book)
                    router.path.append(ReaderRoute.route(for: book))
                }
            )
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderDestinationView(
                    route: route,
                    services: services,
                    userId: user.id,
                    hint: model.hint(for: route.bookId),
                    onRequestPaywall: { model.requestPaywall($0) }
                )
            }
            .navigationDestination(for: ConversationsRoute.self) { _ in
                ConversationsListHost(
                    vm: ConversationsListViewModel.make(services: services),
                    services: services,
                    userId: user.id,
                    onSelect: { convo in model.present(conversation: convo) }
                )
            }
            .task(id: user.id) {
                onCacheUserId(user.id)
                async let sample = services.sampleBookInstaller.installIfNeeded(ownerId: user.id)
                async let reader = services.sampleReaderInstaller.installIfNeeded(ownerId: user.id)
                _ = await (sample, reader)
                #if DEBUG
                // UI-test only: seed a text-dense PDF that stresses the
                // read-aloud page-boundary extraction race (no-op unless
                // RISHI_UITEST=1).
                await UITestDensePDF.installIfNeeded(
                    storage: services.bookFileStorage,
                    ownerId: user.id
                )
                #endif
                await libraryVM.refresh()
            }
        }
        .sheet(isPresented: Bindable(model).showSettings) {
            SettingsSheet(
                services: services,
                user: user,
                onSignedOut: onSignedOut
            )
        }
        .deepLinkHandling(services: services, model: model, libraryVM: libraryVM)
    }
}

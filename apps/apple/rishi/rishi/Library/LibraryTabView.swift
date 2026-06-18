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
import RishiSync

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

    /// Settings gear handler for `LibraryRootView`. On Mac the in-app gear is
    /// removed (Settings is the native menu-bar window, Cmd+,), so this is nil
    /// and the gear is not rendered. iOS/iPadOS keep the gear -> sheet flow.
    private var settingsHandler: (() -> Void) {

        return { model.requestSettings() }
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
                // Phase 32 Plan 32-04 — on Mac the Settings entry point is the
                // native menu-bar window (rishi ▸ Settings…, Cmd+,) from Plan
                // 32-03, so the in-app gear is gone. LibraryRootView renders the
                // gear only `if let onShowSettings`, so passing nil hides it
                // (no RishiLibrary edit). iOS/iPadOS keep the gear + sheet.
                // (`#if` cannot conditionalize a single call argument inline, so
                // the platform choice lives in `macSettingsHandler`.)
                onShowSettings: settingsHandler,
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
                // SYNC: pull the remote library on shell appearance so a fresh
                // device (or cold launch with an existing session) shows the
                // user's whole library, not just locally-cached rows. Shows
                // cached first, then the synced rows after the wave lands.
                // Phase 33 plan 33-02 — Auto Sync gate (§G2 site 3). Guard only
                // the network wave; `refresh` (local DB read) still runs so the
                // library paints from cache even when Auto Sync is OFF. Manual
                // Sync Now is unaffected — the gate is at the auto call site.
                await model.performInitialLibrarySync(
                    refresh: { await libraryVM.refresh() },
                    sync: { if services.readerDefaults.autoSync { _ = await services.syncEngine.runOnce() } }
                )
            }
        }
        // Phase 32 Plan 32-04 — Mac uses the native menu-bar Settings window
        // (Plan 32-03), so the in-app Settings sheet is gated off here. iOS
        // keeps it (gear → requestSettings() → showSettings → this sheet).
        #if !targetEnvironment(macCatalyst)
        .sheet(isPresented: Bindable(model).showSettings) {
            SettingsSheet(
                services: services,
                user: user,
                onSignedOut: onSignedOut
            )
        }
        #endif
        .deepLinkHandling(services: services, model: model, libraryVM: libraryVM)
    }
}

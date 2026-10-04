import Foundation


import SwiftUI

@MainActor
final class ReaderWindowCloseHandle {
    private var actions: [@MainActor () async -> Void] = []
    private var didClose = false

    func register(_ action: @escaping @MainActor () async -> Void) {
        guard !didClose else {
            Task { @MainActor in
                await action()
            }
            return
        }
        actions.append(action)
    }

    func close() async {
        guard !didClose else { return }
        didClose = true
        let actions = self.actions
        self.actions = []
        for action in actions { await action() }
    }
}

#if targetEnvironment(macCatalyst)

/// Stable identity for a Catalyst reader window. The account is part of the
/// identity so a restored window can never be reused for another account.
struct ReaderWindowID: Hashable, Codable, Sendable {
    let userID: UserID
    let bookID: BookID

    init(userID: UserID, bookID: BookID) {
        self.userID = userID
        self.bookID = bookID
    }
}

struct ReaderWindowInput: Hashable, Codable, Sendable, Identifiable {
    let id: ReaderWindowID
    let route: ReaderRoute

    init(userID: UserID, route: ReaderRoute) {
        self.id = ReaderWindowID(userID: userID, bookID: route.bookId)
        self.route = route
    }
}

@MainActor
@Observable
final class PDFReaderPresentationState {
    var requestedMode: PDFViewModeSetting
    private(set) var effectiveMode: PDFViewModeSetting
    var isTransitioning = false

    init(mode: PDFViewModeSetting = .continuous) {
        requestedMode = mode
        effectiveMode = mode
    }

    func beginTransition(to mode: PDFViewModeSetting) {
        requestedMode = mode
        isTransitioning = true
    }

    func didApply(mode: PDFViewModeSetting) {
        effectiveMode = mode
        requestedMode = mode
        isTransitioning = false
    }
}

struct ReaderWindowRestorationState: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let userID: UserID
    let windows: [ReaderWindowInput]

    init(userID: UserID, windows: [ReaderWindowInput], version: Int = currentVersion) {
        self.version = version
        self.userID = userID
        self.windows = windows
    }
}

@MainActor
@Observable
final class ReaderWindowCoordinator {
    private(set) var openWindows: [ReaderWindowID: ReaderWindowInput] = [:]
    private(set) var activeReader: ReaderWindowInput?
    private(set) var activeTheme: ReaderTheme = .default
    private(set) var activePDFViewMode: PDFViewModeSetting = .automatic

    private var openWindowAction: OpenWindowAction?
    private var closeWindowAction: DismissWindowAction?
    private var closeHandles: [ReaderWindowID: ReaderWindowCloseHandle] = [:]
    private var sharedRouteIDs: [ReaderWindowID: UUID] = [:]
    /// Account draining is two-phase: windows may disappear immediately, but
    /// the registry keeps the live runtime until it has issued its bounded
    /// leave. Keep explicit markers so those late window callbacks are local
    /// teardown only.
    private var detachedSharedReadingAccounts = Set<UserID>()
    private var detachedSharedRouteAccounts: [UUID: UserID] = [:]
    private var sharedContextLookup: ((ReaderWindowID, UUID) -> SharedReadingReaderContext?)?
    private var sharedCloseAction: ((UUID, UUID) -> Void)?

    func configure(
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        openWindowAction = openWindow
        closeWindowAction = dismissWindow
    }

    func configureSharedReading(
        contextLookup: @escaping (ReaderWindowID, UUID) -> SharedReadingReaderContext?,
        close: @escaping (UUID, UUID) -> Void
    ) {
        sharedContextLookup = contextLookup
        sharedCloseAction = close
    }

    @discardableResult
    func openShared(_ presentation: SharedReadingReaderPresentation) -> Bool {
        let id = ReaderWindowID(userID: presentation.route.accountID, bookID: presentation.route.readerRoute.bookId)
        guard presentation.context.runtime.accountID == id.userID,
              let openWindowAction,
              let sharedContextLookup,
              sharedContextLookup(id, presentation.route.id) != nil else { return false }
        detachedSharedReadingAccounts.remove(id.userID)
        detachedSharedRouteAccounts.removeValue(forKey: presentation.route.id)
        sharedRouteIDs[id] = presentation.route.id
        let input = ReaderWindowInput(userID: id.userID, route: presentation.route.readerRoute)
        openWindows[input.id] = input
        openWindowAction(id: "reader", value: input)
        return true
    }

    func sharedRouteID(for input: ReaderWindowInput) -> UUID? {
        sharedRouteIDs[input.id]
    }

    func sharedContext(for input: ReaderWindowInput) -> SharedReadingReaderContext? {
        guard !detachedSharedReadingAccounts.contains(input.id.userID),
              let routeID = sharedRouteIDs[input.id],
              detachedSharedRouteAccounts[routeID] == nil
        else { return nil }
        return sharedContextLookup?(input.id, routeID)
    }

    func leaveShared(for input: ReaderWindowInput) {
        guard let routeID = sharedRouteIDs.removeValue(forKey: input.id) else { return }
        guard !detachedSharedReadingAccounts.contains(input.id.userID),
              detachedSharedRouteAccounts[routeID] == nil
        else { return }
        sharedCloseAction?(routeID, input.id.userID)
    }

    /// Called synchronously from the account-transition fence. It must not
    /// unregister a runtime: the registry needs that registration to perform
    /// the bounded remote leave after local presentation has been detached.
    func detachSharedReading(for accountID: UserID) {
        detachedSharedReadingAccounts.insert(accountID)
        for (windowID, routeID) in sharedRouteIDs where windowID.userID == accountID {
            detachedSharedRouteAccounts[routeID] = accountID
        }
    }

    /// The registry completed the drain, so no retained opaque association may
    /// survive into a later account or a restored Catalyst window.
    func clearDetachedSharedReading(for accountID: UserID) {
        detachedSharedReadingAccounts.remove(accountID)
        sharedRouteIDs = sharedRouteIDs.filter { $0.key.userID != accountID }
        detachedSharedRouteAccounts = detachedSharedRouteAccounts.filter { $0.value != accountID }
    }

    @discardableResult
    func open(book: Book, user: User) -> Bool {
        open(route: ReaderRoute.route(for: book), userID: user.id)
    }

    @discardableResult
    func open(route: ReaderRoute, userID: UserID) -> Bool {
        guard let openWindowAction else { return false }
        let input = ReaderWindowInput(userID: userID, route: route)
        let inserted = openWindows.updateValue(input, forKey: input.id) == nil
        openWindowAction(id: "reader", value: input)
        if !inserted {
            // Opening a value that already exists asks SwiftUI to focus the
            // existing scene instead of creating another reader.
            return false
        }
        return true
    }

    func focus(bookID: BookID, userID: UserID) {
        guard let input = openWindows[ReaderWindowID(userID: userID, bookID: bookID)] else {
            return
        }
        openWindowAction?(id: "reader", value: input)
    }

    func close(bookID: BookID, userID: UserID) async {
        let id = ReaderWindowID(userID: userID, bookID: bookID)
        guard let input = openWindows.removeValue(forKey: id) else { return }
        let closeHandle = closeHandles.removeValue(forKey: id)
        leaveShared(for: input)
        await closeHandle?.close()
        closeWindowAction?(value: input)
    }

    /// Deletion must wait for the reader's close handle before the lifecycle
    /// drains source leases and managed-file users. This entry point makes
    /// that ordering explicit for the library's pre-delete hook.
    func closeBeforeBookDeletion(bookID: BookID, userID: UserID) async {
        await close(bookID: bookID, userID: userID)
    }

    func register(_ input: ReaderWindowInput) {
        openWindows[input.id] = input
    }

    func register(
        _ input: ReaderWindowInput,
        closeHandle: ReaderWindowCloseHandle
    ) {
        openWindows[input.id] = input
        closeHandles[input.id] = closeHandle
    }

    func activate(
        _ input: ReaderWindowInput,
        theme: ReaderTheme? = nil,
        pdfViewMode: PDFViewModeSetting? = nil
    ) {
        activeReader = input
        if let theme { activeTheme = theme }
        if let pdfViewMode { activePDFViewMode = pdfViewMode }
        register(input)
    }

    func updateActiveTheme(_ theme: ReaderTheme) {
        activeTheme = theme
    }

    func updateActivePDFViewMode(_ mode: PDFViewModeSetting) {
        activePDFViewMode = mode
    }

    func unregister(
        _ input: ReaderWindowInput,
        closeHandle: ReaderWindowCloseHandle
    ) async {
        let ownsRegistration = closeHandles[input.id] === closeHandle
        if ownsRegistration {
            if openWindows[input.id] == input {
                openWindows.removeValue(forKey: input.id)
            }
            closeHandles.removeValue(forKey: input.id)
            if activeReader == input {
                activeReader = nil
                activeTheme = .default
                activePDFViewMode = .automatic
            }
            // A replaced scene can finish tearing down after its successor
            // has registered the same book. Only the current scene may leave
            // the shared route, and do it before awaiting closeHandle.close().
            leaveShared(for: input)
        }
        await closeHandle.close()
    }

    /// Native Catalyst scene-disconnect entry point. SwiftUI view disappearance
    /// is not guaranteed when the user closes a WindowGroup scene, so the
    /// scene observer routes through the same identity-safe teardown path.
    func sceneDidDisconnect(
        _ input: ReaderWindowInput,
        closeHandle: ReaderWindowCloseHandle
    ) async {
        await unregister(input, closeHandle: closeHandle)
    }

    func deactivate(_ input: ReaderWindowInput) {
        if activeReader?.id == input.id {
            activeReader = nil
        }
    }

    func invalidate(userID: UserID) {
        let ids = openWindows.keys.filter { $0.userID == userID }
        for id in ids {
            Task { @MainActor in
                await self.close(bookID: id.bookID, userID: id.userID)
            }
        }
    }

    func restorationState(userID: UserID) -> ReaderWindowRestorationState {
        ReaderWindowRestorationState(
            userID: userID,
            windows: openWindows.values
                .filter { $0.id.userID == userID }
                .sorted { $0.id.bookID.uuidString < $1.id.bookID.uuidString }
        )
    }

    func restore(
        state: ReaderWindowRestorationState,
        user: User,
        bookStore: any BookStore
    ) async {
        guard state.version == ReaderWindowRestorationState.currentVersion,
              state.userID == user.id else { return }

        for input in state.windows where input.id.userID == user.id {
            guard let book = try? await bookStore.book(input.id.bookID),
                  book.userId == user.id else {
                continue
            }
            open(route: input.route, userID: user.id)
        }
    }
}

#endif

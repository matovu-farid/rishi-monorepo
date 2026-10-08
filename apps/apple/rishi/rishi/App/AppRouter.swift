

import SwiftUI

struct ConversationsRoute: Hashable {}

@MainActor
@Observable
final class AppRouter {

    nonisolated static let shareTokenQueued = Notification.Name("Rishi.shareTokenQueued")
    nonisolated static let shareRedemptionReady = Notification.Name("Rishi.shareRedemptionReady")
    nonisolated static let sessionTokenQueued = Notification.Name("Rishi.sessionTokenQueued")
    nonisolated static let creatorInvitationQueued = Notification.Name("Rishi.creatorInvitationQueued")

    private let sharedReaderAccountIDProvider: @MainActor () -> UUID?

    init(sharedReaderAccountIDProvider: @escaping @MainActor () -> UUID?) {
        self.sharedReaderAccountIDProvider = sharedReaderAccountIDProvider
    }

    var path: NavigationPath = NavigationPath()
    /// The direct shared reader is intentionally separate from `path`: a
    /// NavigationPath is restoration-oriented and cannot safely carry a live
    /// socket/coordinator. This binding is consumed by LibraryTabView only.
    private(set) var sharedReaderRoute: SharedReadingReaderRoute?
    #if targetEnvironment(macCatalyst)
    /// Catalyst keeps the shared-reader identity out of the library's
    /// NavigationStack. The live context is instead attached to the ordinary
    /// reader WindowGroup scene for this book.
    private(set) var catalystSharedReaderRoute: SharedReadingReaderRoute?
    #endif
    private var sharedReaderContexts: [UUID: SharedReadingReaderContext] = [:]
    /// The registry remains the authoritative owner during an account drain.
    /// This marker prevents a late Catalyst/window callback from reviving a
    /// detached context before the post-drain handler releases it.
    private var detachedSharedReaderAccounts = Set<UUID>()

    private var pendingReaderTour: (userID: UserID, bookID: BookID)?
    private var pendingAccountURLs: [URL] = []
    private var pendingAccountDrainTask: Task<Void, Never>?
    private var recentlyResolvedAccountURLs: Set<URL> = []
    private var resolvingAccountURLs: Set<URL> = []

    private static let maxPendingAccountURLs = 8

    private let deepLinks = DeepLinkRouter()
    var onBookResolved: ((Book) -> Void)?

    #if targetEnvironment(macCatalyst)
        var onCatalystBookResolved: ((Book) -> Void)?
        var onCatalystSharedReaderPresented: ((SharedReadingReaderPresentation) -> Bool)?
    #endif

    var onConversationResolved: ((Conversation) -> Void)?

    var onFileURL: ((URL) -> Void)?

    /// Returns whether the live runtime was accepted by the current account's
    /// presentation boundary. The caller owns cleanup on rejection; starting
    /// a separate router leave would race its account-bound compensation.
    @discardableResult
    func presentSharedReader(_ context: SharedReadingReaderContext, for accountID: UUID) -> Bool {
        guard sharedReaderAccountIDProvider() == accountID,
              context.runtime.accountID == accountID,
              context.runtime.readerContext != nil
        else {
            return false
        }
        guard let bookID = context.join.localBookId else {
            return false
        }
        let previousRoute = activeSharedReaderRoute
        detachedSharedReaderAccounts.remove(accountID)
        let route = SharedReadingReaderRoute(
            id: UUID(), accountID: accountID,
            readerRoute: context.join.response.book.format == .pdf
                ? .pdf(bookID) : .epub(bookID),
            sessionID: context.join.response.sessionId
        )
        sharedReaderContexts[route.id] = context
        #if targetEnvironment(macCatalyst)
        // A Catalyst library is its own WindowGroup scene. Do not mutate its
        // navigation state; the normal reader window coordinator owns focus.
        catalystSharedReaderRoute = route
        #else
        // Going directly to the reader must not leave a normal reader below it.
        path = NavigationPath()
        sharedReaderRoute = route
        #endif
        #if targetEnvironment(macCatalyst)
        guard let presentation = sharedReaderPresentation(for: route, accountID: accountID),
              onCatalystSharedReaderPresented?(presentation) == true else {
            catalystSharedReaderRoute = previousRoute
            sharedReaderContexts.removeValue(forKey: route.id)
            return false
        }
        #endif
        if let previousRoute {
            closeSharedReader(id: previousRoute.id, accountID: previousRoute.accountID)
        }
        return true
    }

    func sharedReaderPresentation(for route: SharedReadingReaderRoute, accountID: UUID) -> SharedReadingReaderPresentation? {
        guard !detachedSharedReaderAccounts.contains(accountID),
              route.accountID == accountID, sharedReaderAccountIDProvider() == accountID,
              activeSharedReaderRoute?.id == route.id, let context = sharedReaderContexts[route.id] else { return nil }
        return SharedReadingReaderPresentation(route: route, context: context)
    }

    func sharedReaderPresentation(id: UUID, accountID: UUID) -> SharedReadingReaderPresentation? {
        guard let route = activeSharedReaderRoute, route.id == id else { return nil }
        return sharedReaderPresentation(for: route, accountID: accountID)
    }

    func sharedReaderRouteID(for runtime: SharedReadingSessionRuntime) -> UUID? {
        guard let route = activeSharedReaderRoute,
              sharedReaderContexts[route.id]?.runtime === runtime else { return nil }
        return route.id
    }

    func closeSharedReader(id: UUID, accountID: UUID) {
        // During an account drain, only the registry may close/leave the
        // runtime. A late scene callback must never pre-empt that sequence.
        if detachedSharedReaderAccounts.contains(accountID) {
            clearActiveSharedReaderRoute(id: id)
            return
        }
        guard let context = sharedReaderContexts.removeValue(forKey: id), context.runtime.accountID == accountID else {
            clearActiveSharedReaderRoute(id: id); return
        }
        clearActiveSharedReaderRoute(id: id)
        Task { @MainActor in await context.runtime.leaveAndClose() }
    }

    /// Account transitions must preserve the registry entry until the registry
    /// snapshots it for bounded remote leave. Presentation is detached only.
    func detachSharedReaderPresentation(for accountID: UUID) {
        detachedSharedReaderAccounts.insert(accountID)
        guard activeSharedReaderRoute?.accountID == accountID else { return }
        clearActiveSharedReaderRoute(accountID: accountID)
    }

    /// Called only after the registry finishes draining `accountID`.  The
    /// registry owns local close + bounded remote leave, so this only releases
    /// opaque router references (including in-memory invitations).
    func clearDetachedSharedReaderContexts(for accountID: UUID) {
        guard activeSharedReaderRoute?.accountID != accountID else { return }
        sharedReaderContexts = sharedReaderContexts.filter { $0.value.runtime.accountID != accountID }
        detachedSharedReaderAccounts.remove(accountID)
    }

    func handle(
        url: URL,
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?,
        currentUserID: UserID? = nil,
        currentUserIDProvider: @escaping @MainActor () -> UserID? = { AppDependencies.shared.cachedUserId },
        beforePresentingBook: @escaping @MainActor () async -> Bool = { true }
    ) {
        let destination = deepLinks.route(url)
        switch destination {
        case .authCallback:

            break

        case .shareRedeem(let token):
            Self.enqueueShareToken(token)

        case .sessionRedeem(let token):
            Self.enqueueSessionToken(token)

        case .openBook(let bookId):
            guard !recentlyResolvedAccountURLs.contains(url),
                  resolvingAccountURLs.insert(url).inserted else { return }
            guard let bookStore, let currentUserID else {
                resolvingAccountURLs.remove(url)
                enqueuePendingAccountURL(url)
                return
            }

            Task {
                do {
                    let book = try await bookStore.book(bookId)
                    guard let book else {
                        resolvingAccountURLs.remove(url)
                        enqueuePendingAccountURL(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          currentUserIDProvider() == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        return
                    }
                    guard await beforePresentingBook() else {
                        resolvingAccountURLs.remove(url)
                        enqueuePendingAccountURL(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          currentUserIDProvider() == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        enqueuePendingAccountURL(url)
                        return
                    }
                    removePendingAccountURL(url)
                    markAccountURLResolved(url)
                    present(book: book)
                } catch {
                    resolvingAccountURLs.remove(url)
                    enqueuePendingAccountURL(url)
                    schedulePendingAccountDrain(
                        bookStore: bookStore,
                        conversationStore: conversationStore,
                        currentUserID: currentUserID,
                        beforePresentingBook: beforePresentingBook
                    )
                }
            }

        case .openConversation(let conversationId):
            guard !recentlyResolvedAccountURLs.contains(url),
                  resolvingAccountURLs.insert(url).inserted else { return }
            guard let conversationStore, let currentUserID else {
                resolvingAccountURLs.remove(url)
                enqueuePendingAccountURL(url)
                return
            }

            Task {
                do {
                    let convo = try await conversationStore.conversation(conversationId)
                    guard let convo else {
                        resolvingAccountURLs.remove(url)
                        enqueuePendingAccountURL(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard convo.userId == currentUserID,
                          currentUserIDProvider() == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        return
                    }
                    removePendingAccountURL(url)
                    markAccountURLResolved(url)
                    present(conversation: convo)
                } catch {
                    resolvingAccountURLs.remove(url)
                    enqueuePendingAccountURL(url)
                    schedulePendingAccountDrain(
                        bookStore: bookStore,
                        conversationStore: conversationStore,
                        currentUserID: currentUserID,
                        beforePresentingBook: beforePresentingBook
                    )
                }
            }

        case .unknown:

            if url.isFileURL {
                onFileURL?(url)
            }
        }
    }

    private func enqueuePendingAccountURL(_ url: URL) {
        guard !pendingAccountURLs.contains(url) else { return }
        if pendingAccountURLs.count == Self.maxPendingAccountURLs {
            pendingAccountURLs.removeFirst()
        }
        pendingAccountURLs.append(url)
    }

    private func removePendingAccountURL(_ url: URL) {
        pendingAccountURLs.removeAll { $0 == url }
    }

    private func markAccountURLResolved(_ url: URL) {
        resolvingAccountURLs.remove(url)
        recentlyResolvedAccountURLs.insert(url)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.recentlyResolvedAccountURLs.remove(url)
        }
    }

    private func present(book: Book) {
        if let shared = activeSharedReaderRoute { closeSharedReader(id: shared.id, accountID: shared.accountID) }
        onBookResolved?(book)
        #if targetEnvironment(macCatalyst)
            onCatalystBookResolved?(book)
        #else
            var p = NavigationPath()
            p.append(ReaderRoute.route(for: book))
            path = p
        #endif
    }

    var hasActiveSharedReader: Bool { activeSharedReaderRoute != nil }

    var activeSharedReaderSessionID: String? { activeSharedReaderRoute?.sessionID }

    private var activeSharedReaderRoute: SharedReadingReaderRoute? {
        #if targetEnvironment(macCatalyst)
        catalystSharedReaderRoute
        #else
        sharedReaderRoute
        #endif
    }

    private func clearActiveSharedReaderRoute(id: UUID) {
        #if targetEnvironment(macCatalyst)
        if catalystSharedReaderRoute?.id == id { catalystSharedReaderRoute = nil }
        #else
        if sharedReaderRoute?.id == id { sharedReaderRoute = nil }
        #endif
    }

    private func clearActiveSharedReaderRoute(accountID: UUID) {
        #if targetEnvironment(macCatalyst)
        if catalystSharedReaderRoute?.accountID == accountID { catalystSharedReaderRoute = nil }
        #else
        if sharedReaderRoute?.accountID == accountID { sharedReaderRoute = nil }
        #endif
    }

    private func present(conversation: Conversation) {
        onConversationResolved?(conversation)
    }

    func drainPendingAccountURLs(
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?,
        currentUserID: UserID,
        beforePresentingBook: @escaping @MainActor () async -> Bool = { true }
    ) async {
        guard AppDependencies.shared.cachedUserId == currentUserID else { return }
        while let url = pendingAccountURLs.first {
            guard AppDependencies.shared.cachedUserId == currentUserID else { return }
            if recentlyResolvedAccountURLs.contains(url) {
                pendingAccountURLs.removeFirst()
                continue
            }
            guard resolvingAccountURLs.insert(url).inserted else { return }
            switch deepLinks.route(url) {
            case .openBook(let bookID):
                guard let bookStore else {
                    resolvingAccountURLs.remove(url)
                    return
                }
                do {
                    guard let book = try await bookStore.book(bookID) else {
                        resolvingAccountURLs.remove(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        pendingAccountURLs.removeFirst()
                        continue
                    }
                    guard await beforePresentingBook() else {
                        resolvingAccountURLs.remove(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        continue
                    }
                    pendingAccountURLs.removeFirst()
                    markAccountURLResolved(url)
                    present(book: book)
                } catch {
                    resolvingAccountURLs.remove(url)
                    schedulePendingAccountDrain(
                        bookStore: bookStore,
                        conversationStore: conversationStore,
                        currentUserID: currentUserID,
                        beforePresentingBook: beforePresentingBook
                    )
                    return
                }
            case .openConversation(let conversationID):
                guard let conversationStore else {
                    resolvingAccountURLs.remove(url)
                    return
                }
                do {
                    guard let conversation = try await conversationStore.conversation(conversationID) else {
                        resolvingAccountURLs.remove(url)
                        schedulePendingAccountDrain(
                            bookStore: bookStore,
                            conversationStore: conversationStore,
                            currentUserID: currentUserID,
                            beforePresentingBook: beforePresentingBook
                        )
                        return
                    }
                    guard conversation.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        pendingAccountURLs.removeFirst()
                        continue
                    }
                    pendingAccountURLs.removeFirst()
                    markAccountURLResolved(url)
                    present(conversation: conversation)
                } catch {
                    resolvingAccountURLs.remove(url)
                    schedulePendingAccountDrain(
                        bookStore: bookStore,
                        conversationStore: conversationStore,
                        currentUserID: currentUserID,
                        beforePresentingBook: beforePresentingBook
                    )
                    return
                }
            default:
                resolvingAccountURLs.remove(url)
                pendingAccountURLs.removeFirst()
            }
        }
    }

    private func schedulePendingAccountDrain(
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?,
        currentUserID: UserID,
        beforePresentingBook: @escaping @MainActor () async -> Bool = { true }
    ) {
        guard pendingAccountDrainTask == nil else { return }
        pendingAccountDrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.pendingAccountDrainTask = nil
            await self.drainPendingAccountURLs(
                bookStore: bookStore,
                conversationStore: conversationStore,
                currentUserID: currentUserID,
                beforePresentingBook: beforePresentingBook
            )
        }
    }

    /// Queues a share token at the app boundary. Universal links can arrive
    /// through SwiftUI, UIApplicationDelegate, or scene restoration, so all
    /// ingress paths share the same durable, de-duplicating queue.
    nonisolated static func enqueueShareToken(_ token: String) {
        guard !token.isEmpty else { return }
        Task {
            await PendingShareStore.shared.enqueue(token: token)
            Log.event("sharing.pending_token.queued")
            await MainActor.run {
                NotificationCenter.default.post(name: Self.shareTokenQueued, object: nil)
            }
        }
    }

    nonisolated static func enqueueSessionToken(_ token: String) {
        guard !token.isEmpty else { return }
        Task {
            await PendingSessionInviteStore.anonymous.save(token: token)
            await MainActor.run {
            NotificationCenter.default.post(name: Self.sessionTokenQueued, object: token)
            }
        }
    }

    @discardableResult
    nonisolated static func enqueueShareToken(from url: URL) -> Bool {
        guard case .shareRedeem(let token) = DeepLinkRouter().route(url) else { return false }
        guard !token.isEmpty else { return false }
        Log.event("sharing.deep_link.received", data: [
            "scheme": url.scheme?.lowercased() ?? "",
            "host": url.host?.lowercased() ?? "",
            "path": url.path,
        ])
        enqueueShareToken(token)
        return true
    }

    @discardableResult
    nonisolated static func enqueueSessionToken(from url: URL) -> Bool {
        guard case .sessionRedeem(let token) = DeepLinkRouter().route(url), !token.isEmpty else { return false }
        enqueueSessionToken(token)
        return true
    }

    /// Associates an invitation with the creator's in-process redemption only.
    /// The URL is never logged or persisted; the existing safe session-token
    /// ingress extracts and persists only its token.
    @discardableResult
    nonisolated static func enqueueCreatedSession(_ invitation: SharedReadingInvitation) -> Bool {
        guard enqueueSessionToken(from: invitation.shareURL) else { return false }
        NotificationCenter.default.post(name: Self.creatorInvitationQueued, object: invitation)
        return true
    }

    @discardableResult
    nonisolated static func enqueueShareOrSessionToken(from url: URL) -> Bool {
        if enqueueShareToken(from: url) { return true }
        return enqueueSessionToken(from: url)
    }

    func showLibraryRoot() {
        path = NavigationPath()
    }

    func showConversations() {
        var p = NavigationPath()
        p.append(ConversationsRoute())
        path = p
    }

    /// Transient, account-scoped request from the first-library import flow.
    /// It is intentionally not part of the persisted NavigationPath.
    func requestReaderTour(for bookID: BookID, userID: UserID) {
        pendingReaderTour = (userID: userID, bookID: bookID)
    }

    func takeReaderTour(for bookID: BookID, userID: UserID) -> Bool {
        guard let pendingReaderTour,
              pendingReaderTour.userID == userID,
              pendingReaderTour.bookID == bookID
        else { return false }
        self.pendingReaderTour = nil
        return true
    }

    func clearReaderTourRequest() {
        pendingReaderTour = nil
    }

    func applyRestored(
        tabRaw _: String,
        openBookIdRaw _: String,
        bookStore _: (any BookStore)?
    ) async {

    }

    func persistCells() -> (tabRaw: String, openBookIdRaw: String) {

        let state = RishiSceneState(selectedTab: .library, openBookId: nil)
        let tabRaw = state.encodeForStorage()
        let openBookIdRaw = NavigationPath.encodeForStorage(path)
        return (tabRaw: tabRaw, openBookIdRaw: openBookIdRaw)
    }
}



import SwiftUI

struct ConversationsRoute: Hashable {}

@MainActor
@Observable
final class AppRouter {

    nonisolated static let shareTokenQueued = Notification.Name("Rishi.shareTokenQueued")
    nonisolated static let shareRedemptionReady = Notification.Name("Rishi.shareRedemptionReady")

    var path: NavigationPath = NavigationPath()

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
    #endif

    var onConversationResolved: ((Conversation) -> Void)?

    var onFileURL: ((URL) -> Void)?

    func handle(
        url: URL,
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?,
        currentUserID: UserID? = nil
    ) {
        let destination = deepLinks.route(url)
        switch destination {
        case .authCallback:

            break

        case .shareRedeem(let token):
            Self.enqueueShareToken(token)

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
                            currentUserID: currentUserID
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
                        resolvingAccountURLs.remove(url)
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
                        currentUserID: currentUserID
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
                            currentUserID: currentUserID
                        )
                        return
                    }
                    guard convo.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
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
                        currentUserID: currentUserID
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
        onBookResolved?(book)
        #if targetEnvironment(macCatalyst)
            onCatalystBookResolved?(book)
        #else
            var p = NavigationPath()
            p.append(ReaderRoute.route(for: book))
            path = p
        #endif
    }

    private func present(conversation: Conversation) {
        onConversationResolved?(conversation)
    }

    func drainPendingAccountURLs(
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?,
        currentUserID: UserID
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
                            currentUserID: currentUserID
                        )
                        return
                    }
                    guard book.userId == currentUserID,
                          AppDependencies.shared.cachedUserId == currentUserID else {
                        resolvingAccountURLs.remove(url)
                        pendingAccountURLs.removeFirst()
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
                        currentUserID: currentUserID
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
                            currentUserID: currentUserID
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
                        currentUserID: currentUserID
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
        currentUserID: UserID
    ) {
        guard pendingAccountDrainTask == nil else { return }
        pendingAccountDrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.pendingAccountDrainTask = nil
            await self.drainPendingAccountURLs(
                bookStore: bookStore,
                conversationStore: conversationStore,
                currentUserID: currentUserID
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

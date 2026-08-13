

import SwiftUI

struct ConversationsRoute: Hashable {}

@MainActor
@Observable
final class AppRouter {

    nonisolated static let shareTokenQueued = Notification.Name("Rishi.shareTokenQueued")
    nonisolated static let shareRedemptionReady = Notification.Name("Rishi.shareRedemptionReady")

    var path: NavigationPath = NavigationPath()

    private var pendingReaderTour: (userID: UserID, bookID: BookID)?

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
        conversationStore: (any ConversationStore)?
    ) {
        let destination = deepLinks.route(url)
        switch destination {
        case .authCallback:

            break

        case .shareRedeem(let token):
            Self.enqueueShareToken(token)

        case .openBook(let bookId):
            guard let bookStore else { return }

            Task {
                let book: Book? = try? await bookStore.book(bookId)
                guard let book else { return }

                onBookResolved?(book)
                #if targetEnvironment(macCatalyst)
                    onCatalystBookResolved?(book)
                #else
                    var p = NavigationPath()
                    p.append(ReaderRoute.route(for: book))
                    path = p
                #endif
            }

        case .openConversation(let conversationId):
            guard let conversationStore else { return }

            Task {
                let convo: Conversation? =
                    try? await conversationStore.conversation(conversationId)
                guard let convo else { return }
                onConversationResolved?(convo)
            }

        case .unknown:

            if url.isFileURL {
                onFileURL?(url)
            }
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

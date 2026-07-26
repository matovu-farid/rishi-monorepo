

import Testing
import Foundation
import SwiftUI



@testable import rishi



@MainActor
@Suite("AppRouter")
struct AppRouterTests {

    

    @Test("showLibraryRoot clears the navigation path")
    func showLibraryRootClearsPath() {
        let router = AppRouter()
        router.path.append(ReaderRoute.epub(UUID()))
        #expect(!router.path.isEmpty)

        router.showLibraryRoot()
        #expect(router.path.isEmpty)
    }

    @Test("showConversations sets path to a single ConversationsRoute")
    func showConversationsPushesRoute() {
        let router = AppRouter()
        router.showConversations()
        #expect(router.path.count == 1)
    }

    @Test("showLibraryRoot after showConversations resets to empty")
    func showLibraryRootAfterConversations() {
        let router = AppRouter()
        router.showConversations()
        router.showLibraryRoot()
        #expect(router.path.isEmpty)
    }

    

    @Test("Unknown/garbage deep link leaves path empty")
    func unknownDeepLinkNoOp() {
        let router = AppRouter()
        router.handle(
            url: URL(string: "https://other-domain.com/app/book/x")!,
            bookStore: nil,
            conversationStore: nil
        )
        #expect(router.path.isEmpty)
    }

    @Test("authCallback deep link is a no-op (path stays empty)")
    func authCallbackNoOp() {
        let router = AppRouter()
        router.handle(
            url: URL(string: "rishi://auth/callback?token=xyz")!,
            bookStore: nil,
            conversationStore: nil
        )
        #expect(router.path.isEmpty)
    }

    @Test("shareRedeem deep link is a no-op (path stays empty)")
    func shareRedeemNoOp() {
        let router = AppRouter()
        router.handle(
            url: URL(string: "rishi://sharing/join?token=abc")!,
            bookStore: nil,
            conversationStore: nil
        )
        #expect(router.path.isEmpty)
    }

    

    @Test("openBook deep link resolves book, fires onBookResolved, replaces path")
    func openBookHappyPath() async {
        let bookId = UUID()
        let book = Book(
            id: bookId,
            userId: UUID(),
            title: "Test Book",
            formatType: .epub,
            fileURL: "test.epub"
        )
        let store = InMemoryBookStore(initial: [book])
        let router = AppRouter()
        
        router.path.append(ReaderRoute.epub(UUID()))
        #expect(router.path.count == 1)

        var resolvedBook: Book?
        router.onBookResolved = { b in resolvedBook = b }

        let url = URL(string: "rishi://book/\(bookId.uuidString)")!
        router.handle(url: url, bookStore: store, conversationStore: nil)

        
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(resolvedBook?.id == bookId)
        
        #expect(router.path.count == 1)
    }

    @Test("openConversation deep link resolves conversation, fires onConversationResolved")
    func openConversationHappyPath() async {
        let convoId = UUID()
        let convo = Conversation(
            id: convoId,
            userId: UUID(),
            title: "Test Conversation"
        )
        let store = InMemoryConversationStore(initial: [convo])
        let router = AppRouter()

        var resolvedConvo: Conversation?
        router.onConversationResolved = { c in resolvedConvo = c }

        let url = URL(string: "rishi://conversation/\(convoId.uuidString)")!
        router.handle(url: url, bookStore: nil, conversationStore: store)

        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(resolvedConvo?.id == convoId)
        
        #expect(router.path.isEmpty)
    }

    @Test("openBook with nil bookStore is a no-op")
    func openBookNilStorNoOp() {
        let router = AppRouter()
        let url = URL(string: "rishi://book/\(UUID().uuidString)")!
        router.handle(url: url, bookStore: nil, conversationStore: nil)
        #expect(router.path.isEmpty)
    }

    

    @Test("persistCells returns non-empty tabRaw (schema continuity)")
    func persistCellsTabRawNonEmpty() {
        let router = AppRouter()
        let cells = router.persistCells()
        
        #expect(!cells.tabRaw.isEmpty)
        
        let state = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: cells.tabRaw,
            openBookIdRaw: ""
        )
        #expect(state.state.selectedTab == .library)
    }

    @Test("persistCells returns empty openBookIdRaw when path is empty")
    func persistCellsOpenBookIdRawEmpty() {
        let router = AppRouter()
        router.showLibraryRoot()
        let cells = router.persistCells()
        
        
        let decoded = NavigationPath.decodeFromStorage(cells.openBookIdRaw)
        #expect(decoded.isEmpty)
    }

    @Test("persistCells round-trips a pushed reader route back through decodeFromStorage with matching UUID")
    func persistCellsRoundTripsPath() {
        let router = AppRouter()
        let id = UUID()
        router.path.append(ReaderRoute.epub(id))

        let cells = router.persistCells()
        let decoded = NavigationPath.decodeFromStorage(cells.openBookIdRaw)
        #expect(decoded.count == 1)

        
        
        
        let rawRoute = ReaderRoute.encodeForStorage(.epub(id))
        let roundTripped = ReaderRoute.decodeFromStorage(rawRoute)
        #expect(roundTripped == .epub(id))
    }

    
    //
    
    
    
    
    

    @Test("applyRestored with empty cells leaves path empty")
    func applyRestoredEmptyCells() async {
        let router = AppRouter()
        await router.applyRestored(tabRaw: "", openBookIdRaw: "", bookStore: nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored ignores a stored full NavigationPath and starts at the library")
    func applyRestoredIgnoresFullPath() async {
        let router = AppRouter()
        
        var src = NavigationPath()
        src.append(ReaderRoute.epub(UUID()))
        let rawPath = NavigationPath.encodeForStorage(src)

        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawPath, bookStore: nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored ignores a stored Legacy A reader route and starts at the library")
    func applyRestoredIgnoresLegacyA() async {
        let router = AppRouter()
        let rawRoute = ReaderRoute.encodeForStorage(.pdf(UUID()))
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawRoute, bookStore: nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored ignores a stored Legacy B bare UUID and never resolves the book")
    func applyRestoredIgnoresLegacyB() async {
        let bookId = UUID()
        let book = Book(
            id: bookId,
            userId: UUID(),
            title: "Legacy Book",
            formatType: .pdf,
            fileURL: "legacy.pdf"
        )
        let store = InMemoryBookStore(initial: [book])
        let router = AppRouter()

        var resolvedBook: Book?
        router.onBookResolved = { b in resolvedBook = b }

        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(
            tabRaw: tabRaw,
            openBookIdRaw: bookId.uuidString,
            bookStore: store
        )

        
        #expect(resolvedBook == nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored preserves a reader route already pushed by a deep link")
    func applyRestoredPreservesDeepLinkRoute() async {
        let router = AppRouter()
        
        
        router.path.append(ReaderRoute.epub(UUID()))
        #expect(router.path.count == 1)

        var src = NavigationPath()
        src.append(ReaderRoute.epub(UUID()))
        let rawPath = NavigationPath.encodeForStorage(src)

        await router.applyRestored(tabRaw: "", openBookIdRaw: rawPath, bookStore: nil)
        
        #expect(router.path.count == 1)
    }

    @Test("Bare-UUID legacy cell does NOT decode as ReaderRoute (guards legacy B branch)")
    func bareUUIDNotDecodedAsReaderRoute() {
        
        
        
        let bare = UUID().uuidString
        #expect(ReaderRoute.decodeFromStorage(bare) == nil)
    }
}

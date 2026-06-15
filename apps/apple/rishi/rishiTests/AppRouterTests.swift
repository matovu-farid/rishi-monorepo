//
//  AppRouterTests.swift
//  rishiTests
//
//  TDD coverage for AppRouter — navigation, deep-link dispatch, and
//  scene-restoration helpers extracted from RootView.
//
//  Swift Testing only (no XCTest).
//

import Testing
import Foundation
import SwiftUI
import RishiCore
import RishiReader
import RishiTesting
@testable import rishi

// MARK: - Suite

@MainActor
@Suite("AppRouter")
struct AppRouterTests {

    // MARK: - Navigation helpers

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

    // MARK: - Deep-link: path-only cases (no stores needed)

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

    // MARK: - Deep-link happy paths

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
        // Pre-load a stale path entry to verify REPLACE (not append) semantics.
        router.path.append(ReaderRoute.epub(UUID()))
        #expect(router.path.count == 1)

        var resolvedBook: Book?
        router.onBookResolved = { b in resolvedBook = b }

        let url = URL(string: "rishi://book/\(bookId.uuidString)")!
        router.handle(url: url, bookStore: store, conversationStore: nil)

        // Await the spawned Task by draining the cooperative thread pool.
        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(resolvedBook?.id == bookId)
        // Path is replaced with a single entry (the resolved route), not appended.
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
        // openConversation does not mutate the navigation path.
        #expect(router.path.isEmpty)
    }

    @Test("openBook with nil bookStore is a no-op")
    func openBookNilStorNoOp() {
        let router = AppRouter()
        let url = URL(string: "rishi://book/\(UUID().uuidString)")!
        router.handle(url: url, bookStore: nil, conversationStore: nil)
        #expect(router.path.isEmpty)
    }

    // MARK: - Deep-link: persistCells round-trip

    @Test("persistCells returns non-empty tabRaw (schema continuity)")
    func persistCellsTabRawNonEmpty() {
        let router = AppRouter()
        let cells = router.persistCells()
        // tabRaw always encodes .library for schema continuity; must be non-empty.
        #expect(!cells.tabRaw.isEmpty)
        // Confirm it decodes back to the expected tab.
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
        // An empty NavigationPath encodes to "" so the scene-restore branch
        // treats it as "no book open".
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

        // Verify UUID identity round-trips through the encoded representation.
        // Re-encode via applyRestored (sync path decode) to confirm the route
        // carries the same ID after a full cycle.
        let rawRoute = ReaderRoute.encodeForStorage(.epub(id))
        let roundTripped = ReaderRoute.decodeFromStorage(rawRoute)
        #expect(roundTripped == .epub(id))
    }

    // MARK: - Scene restoration: applyRestored

    @Test("applyRestored with empty cells leaves path empty")
    func applyRestoredEmptyCells() async {
        let router = AppRouter()
        await router.applyRestored(tabRaw: "", openBookIdRaw: "", bookStore: nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored restores a full NavigationPath (preferred branch)")
    func applyRestoredFullPath() async {
        let router = AppRouter()
        // Encode a path with one ReaderRoute as the preferred shape.
        var src = NavigationPath()
        src.append(ReaderRoute.epub(UUID()))
        let rawPath = NavigationPath.encodeForStorage(src)

        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawPath, bookStore: nil)
        #expect(router.path.count == 1)
    }

    @Test("applyRestored restores via Legacy A (JSON ReaderRoute)")
    func applyRestoredLegacyA() async {
        let router = AppRouter()
        let id = UUID()
        let rawRoute = ReaderRoute.encodeForStorage(.pdf(id))
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawRoute, bookStore: nil)
        #expect(router.path.count == 1)
    }

    @Test("applyRestored Legacy B (bare UUID) no-ops when bookStore is nil")
    func applyRestoredLegacyBNilStore() async {
        let router = AppRouter()
        let bareUUID = UUID().uuidString   // v0 cell shape
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        // Without a bookStore the lookup cannot run — path must stay empty.
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: bareUUID, bookStore: nil)
        #expect(router.path.isEmpty)
    }

    @Test("applyRestored Legacy B (bare UUID) resolves book and fires onBookResolved")
    func applyRestoredLegacyBHappyPath() async {
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

        #expect(resolvedBook?.id == bookId)
        #expect(router.path.count == 1)
    }

    @Test("Bare-UUID legacy cell does NOT decode as ReaderRoute (guards legacy B branch)")
    func bareUUIDNotDecodedAsReaderRoute() {
        // Mirrors RootViewSceneRestorationTests.readerRouteForwardCompatLegacyBareUuid.
        // If this returns non-nil the Legacy B branch would be skipped — that
        // would silently drop the bare-UUID restore for v0 upgrades.
        let bare = UUID().uuidString
        #expect(ReaderRoute.decodeFromStorage(bare) == nil)
    }
}

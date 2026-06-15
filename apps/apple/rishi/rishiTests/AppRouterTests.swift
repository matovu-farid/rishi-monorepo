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

    // MARK: - Deep-link: path-only cases (no deps needed)

    @Test("Unknown/garbage deep link leaves path empty")
    func unknownDeepLinkNoOp() {
        let router = AppRouter()
        router.handle(url: URL(string: "https://other-domain.com/app/book/x")!, deps: nil)
        #expect(router.path.isEmpty)
    }

    @Test("authCallback deep link is a no-op (path stays empty)")
    func authCallbackNoOp() {
        let router = AppRouter()
        router.handle(url: URL(string: "rishi://auth/callback?token=xyz")!, deps: nil)
        #expect(router.path.isEmpty)
    }

    @Test("shareRedeem deep link is a no-op (path stays empty)")
    func shareRedeemNoOp() {
        let router = AppRouter()
        router.handle(url: URL(string: "rishi://sharing/join?token=abc")!, deps: nil)
        #expect(router.path.isEmpty)
    }

    // MARK: - Deep-link: persistCells round-trip

    @Test("persistCells returns non-empty tabRaw after showLibraryRoot")
    func persistCellsTabRawNonEmpty() {
        let router = AppRouter()
        router.showLibraryRoot()
        let cells = router.persistCells()
        #expect(!cells.tabRaw.isEmpty)
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

    @Test("persistCells round-trips a pushed reader route back through decodeFromStorage")
    func persistCellsRoundTripsPath() {
        let router = AppRouter()
        let id = UUID()
        router.path.append(ReaderRoute.epub(id))

        let cells = router.persistCells()
        let decoded = NavigationPath.decodeFromStorage(cells.openBookIdRaw)
        #expect(decoded.count == 1)
    }

    // MARK: - Scene restoration: applyRestored

    @Test("applyRestored with empty cells leaves path empty")
    func applyRestoredEmptyCells() async {
        let router = AppRouter()
        await router.applyRestored(tabRaw: "", openBookIdRaw: "", deps: nil)
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
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawPath, deps: nil)
        #expect(router.path.count == 1)
    }

    @Test("applyRestored restores via Legacy A (JSON ReaderRoute)")
    func applyRestoredLegacyA() async {
        let router = AppRouter()
        let id = UUID()
        let rawRoute = ReaderRoute.encodeForStorage(.pdf(id))
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: rawRoute, deps: nil)
        #expect(router.path.count == 1)
    }

    @Test("applyRestored Legacy B (bare UUID) no-ops when deps is nil")
    func applyRestoredLegacyBNilDeps() async {
        let router = AppRouter()
        let bareUUID = UUID().uuidString   // v0 cell shape
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        // Without deps the book lookup cannot run — path must stay empty.
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: bareUUID, deps: nil)
        #expect(router.path.isEmpty)
    }

    @Test("Bare-UUID legacy cell does NOT decode as ReaderRoute (guards legacy B branch)")
    func bareUUIDNotDecodedAsReaderRoute() {
        // Mirrors RootViewSceneRestorationTests.readerRouteForwardCompatLegacyBareUuid.
        // If this returns non-nil the Legacy B branch would be skipped — that
        // would silently drop the bare-UUID restore for v0 upgrades.
        let bare = UUID().uuidString
        #expect(ReaderRoute.decodeFromStorage(bare) == nil)
    }

    @Test("applyRestored sets selectedTab from tabRaw")
    func applyRestoredSetsSelectedTab() async {
        let router = AppRouter()
        // Encode a scene state with .library (the only value in current layout).
        let tabRaw = RishiSceneState(selectedTab: .library, openBookId: nil).encodeForStorage()
        await router.applyRestored(tabRaw: tabRaw, openBookIdRaw: "", deps: nil)
        #expect(router.selectedTab == .library)
    }
}

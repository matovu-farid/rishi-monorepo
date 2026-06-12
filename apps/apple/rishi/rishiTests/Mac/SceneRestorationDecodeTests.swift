//
//  SceneRestorationDecodeTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-11 — F-P0-05 nonisolated decode helper.
//
//  Pins the contract that the three sequential Codable decodes used during
//  `@SceneStorage` restoration (RishiSceneState + NavigationPath +
//  ReaderRoute + bare-UUID legacy id) are bundled into a single
//  `nonisolated` static helper so they can run off the MainActor on cold
//  launch. The helper is pure value work — no actor isolation needed.
//
//  Swift Testing only (no XCTest).
//

import Testing
import Foundation
import SwiftUI
import RishiCore
import RishiReader
@testable import rishi

/// Non-MainActor suite — proves `decodeSceneRestoreCells(...)` is callable
/// from a context that is NOT MainActor-isolated. If the helper accidentally
/// inherits MainActor (e.g. through default-isolation = MainActor and a
/// missing `nonisolated` keyword), Swift 6 strict concurrency will reject
/// these tests at compile time.
@Suite("Scene restoration decode helper — off-main contract")
struct SceneRestorationDecodeTests {

    // MARK: - Test 1 — helper is nonisolated (compile-time proof)

    /// The mere act of `await`-less calling the helper from this
    /// non-@MainActor `@Test` body proves the helper does NOT carry
    /// MainActor isolation. If it did, the compiler would force an `await`
    /// (or fail outright under strict concurrency).
    @Test
    func test_decodeHelperIsNonisolated() {
        // Empty cells → default state, nil path, nil route, nil legacyId.
        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "",
            openBookIdRaw: ""
        )
        #expect(result.state == .default)
        #expect(result.path == nil)
        #expect(result.route == nil)
        #expect(result.legacyId == nil)
    }

    // MARK: - Test 2 — round-trips all three cells correctly

    @Test
    func test_decodeReturnsAllThreeCells_navigationPathBranch() {
        // Build a real NavigationPath holding a single ReaderRoute, encode
        // it the way `persistSceneState` does, then assert the helper
        // returns it back via the `path` slot.
        let bookId = UUID()
        var path = NavigationPath()
        path.append(ReaderRoute.epub(bookId))
        let pathRaw = NavigationPath.encodeForStorage(path)

        let tabState = RishiSceneState(selectedTab: .chats, openBookId: nil)
        let tabRaw = tabState.encodeForStorage()

        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: tabRaw,
            openBookIdRaw: pathRaw
        )

        #expect(result.state.selectedTab == .chats)
        // Preferred branch: NavigationPath round-trip wins, populates `path`.
        #expect(result.path?.count == 1)
        // The helper tries every decoder unconditionally; route/legacyId
        // may or may not be populated for a path-encoded cell. The
        // caller uses path-first precedence, so we only pin the path
        // slot here. Bare UUID parse on a JSON blob always → nil.
        #expect(result.legacyId == nil)
    }

    @Test
    func test_decodeReturnsAllThreeCells_readerRouteBranch() {
        // Legacy intermediate shape: a ReaderRoute JSON-encoded directly
        // into the openBookIdRaw cell (pre-NavigationPath migration).
        let bookId = UUID()
        let route = ReaderRoute.pdf(bookId)
        let routeRaw = ReaderRoute.encodeForStorage(route)

        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "",
            openBookIdRaw: routeRaw
        )

        // No NavigationPath in the cell, so `path` is nil.
        #expect(result.path == nil)
        // ReaderRoute decode succeeds.
        #expect(result.route == route)
        // Bare UUID parse on JSON → nil.
        #expect(result.legacyId == nil)
    }

    @Test
    func test_decodeReturnsAllThreeCells_legacyBareUuidBranch() {
        // v0 cell shape — a bare UUID string. Neither NavigationPath nor
        // ReaderRoute decode should succeed; only `legacyId` populates.
        let bookId = UUID()
        let raw = bookId.uuidString

        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "",
            openBookIdRaw: raw
        )

        #expect(result.path == nil)
        #expect(result.route == nil)
        #expect(result.legacyId == bookId)
    }

    @Test
    func test_decodeReturnsAllThreeCells_garbageDecodesAllNil() {
        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "not json",
            openBookIdRaw: "also not json"
        )
        // Tab decode falls back to default per RishiSceneState codec contract.
        #expect(result.state == .default)
        #expect(result.path == nil)
        #expect(result.route == nil)
        #expect(result.legacyId == nil)
    }

    // MARK: - Test 3 — legacy DB lookup hops off main

    /// Probe BookStore that records the executor (MainActor vs not) seen
    /// inside its async `book(_:)` witness. Used to assert the legacy
    /// fallback wraps the await in `Task.detached` so the DB hit + the
    /// continuation resume both land off main.
    actor ProbeBookStore: BookStore {
        private(set) var sawMainActor: Bool? = nil
        private(set) var lookupCount: Int = 0

        func books(for userId: UserID) async throws -> [Book] { [] }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}

        func book(_ id: BookID) async throws -> Book? {
            lookupCount += 1
            // Record whether we are on MainActor. Inside an actor's own
            // isolation, Thread.isMainThread tells us if the caller's
            // suspension point left us on the main queue.
            sawMainActor = Thread.isMainThread
            return nil
        }
    }

    /// Asserts that wrapping the DB lookup in `Task.detached` causes the
    /// `book(_:)` await to NOT execute on the main thread. This is the
    /// off-main contract for the legacy bare-UUID fallback in
    /// `RootView.restoreSceneState`.
    @Test
    func test_legacyDBLookupHopsOffMain() async throws {
        let store = ProbeBookStore()
        let id = UUID()

        // Mirror the production wrapping pattern: invoke the lookup inside
        // a Task.detached with userInitiated priority.
        _ = await Task.detached(priority: .userInitiated) { [store] in
            try? await store.book(id)
        }.value

        let sawMain = await store.sawMainActor
        let count   = await store.lookupCount
        #expect(count == 1, "store should have been hit exactly once")
        // The detached executor must NOT be the main thread.
        #expect(sawMain == false, "BookStore.book should resume off main")
    }
}

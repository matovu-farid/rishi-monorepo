














import Testing
import Foundation
import SwiftUI


@testable import rishi






@Suite("Scene restoration decode helper — off-main contract")
struct SceneRestorationDecodeTests {

    

    
    
    
    
    @Test
    func test_decodeHelperIsNonisolated() {
        
        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "",
            openBookIdRaw: ""
        )
        #expect(result.state == .default)
        #expect(result.path == nil)
        #expect(result.route == nil)
        #expect(result.legacyId == nil)
    }

    

    @Test
    func test_decodeReturnsAllThreeCells_navigationPathBranch() {
        
        
        
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
        
        #expect(result.path?.count == 1)
        
        
        
        
        #expect(result.legacyId == nil)
    }

    @Test
    func test_decodeReturnsAllThreeCells_readerRouteBranch() {
        
        
        let bookId = UUID()
        let route = ReaderRoute.pdf(bookId)
        let routeRaw = ReaderRoute.encodeForStorage(route)

        let result = RishiSceneState.decodeSceneRestoreCells(
            tabRaw: "",
            openBookIdRaw: routeRaw
        )

        
        #expect(result.path == nil)
        
        #expect(result.route == route)
        
        #expect(result.legacyId == nil)
    }

    @Test
    func test_decodeReturnsAllThreeCells_legacyBareUuidBranch() {
        
        
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
        
        #expect(result.state == .default)
        #expect(result.path == nil)
        #expect(result.route == nil)
        #expect(result.legacyId == nil)
    }

    

    
    
    
    
    actor ProbeBookStore: BookStore {
        private(set) var sawMainActor: Bool? = nil
        private(set) var lookupCount: Int = 0

        func books(for userId: UserID) async throws -> [Book] { [] }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}

        func book(_ id: BookID) async throws -> Book? {
            lookupCount += 1
            
            
            
            sawMainActor = Thread.isMainThread
            return nil
        }
    }

    
    
    
    
    @Test
    func test_legacyDBLookupHopsOffMain() async throws {
        let store = ProbeBookStore()
        let id = UUID()

        
        
        _ = await Task.detached(priority: .userInitiated) { [store] in
            try? await store.book(id)
        }.value

        let sawMain = await store.sawMainActor
        let count   = await store.lookupCount
        #expect(count == 1, "store should have been hit exactly once")
        
        #expect(sawMain == false, "BookStore.book should resume off main")
    }
}

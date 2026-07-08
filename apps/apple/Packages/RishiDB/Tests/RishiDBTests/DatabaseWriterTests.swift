import Foundation
import Testing
import RishiCore
@testable import RishiDB

@Suite("RishiDB bootstrap")
struct DatabaseWriterTests {

    @Test("Every store accepts the shared SwiftData facade")
    func storesAcceptSharedFacade() throws {
        let facade = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        _ = SwiftDataBookStore(dbStore: facade)
        _ = SwiftDataPositionStore(dbStore: facade)
        _ = SwiftDataHighlightStore(dbStore: facade)
        _ = SwiftDataConversationStore(dbStore: facade)
        _ = SwiftDataMessageStore(dbStore: facade)
    }

    @Test("makeStore opens a usable on-disk store")
    func makeStoreOpensAndPersists() async throws {
        let url = try tmpDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let facade = try RishiDB.makeStore(at: url)
        let store = SwiftDataBookStore(dbStore: facade)

        let userId = UUID()
        let book = Book(
            userId: userId,
            title: "Pool Test",
            formatType: .epub,
            fileURL: "books/p.epub"
        )
        try await store.upsert(book)

        let fetched = try await store.books(for: userId)
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Pool Test")
    }

    @Test("makeModelContainer can bootstrap both memory and disk stores")
    func makeModelContainerBootstraps() throws {
        let inMemory = try RishiDB.makeModelContainer(at: URL(fileURLWithPath: ":memory:"))
        let diskURL = try tmpDBURL()
        defer { try? FileManager.default.removeItem(at: diskURL.deletingLastPathComponent()) }
        let onDisk = try RishiDB.makeModelContainer(at: diskURL)
        #expect(inMemory.schema.entities.count == onDisk.schema.entities.count)
        #expect(inMemory.schema.entitiesByName["BookEntity"] != nil)
    }

    private func tmpDBURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rishi.sqlite")
    }
}

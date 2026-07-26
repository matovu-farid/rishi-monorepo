@testable import rishi
import Foundation
import SwiftData
import Testing



@Suite("RishiDB package smoke")
struct RishiDB_PackageSmokeTests {

    @Test func makeModelContainerInMemorySucceeds() throws {
        let container = try RishiDB.makeModelContainer(at: URL(fileURLWithPath: ":memory:"))
        let context = ModelContext(container)
        let book = BookEntity(
            id: UUID(),
            userId: UUID(),
            title: "Smoke Test",
            author: nil,
            formatTypeRawValue: "epub",
            addedAt: .now,
            openedAt: nil,
            fileURL: "books/smoke.epub",
            coverPath: nil,
            positionId: nil,
            conversationId: nil
        )
        context.insert(book)
        try context.save()

        let fetched: [BookEntity] = try context.fetch(FetchDescriptor<BookEntity>())
        #expect(fetched.first?.title == "Smoke Test")
    }

    @Test func apiVersionIsSchemaMarker() {
        #expect(RishiDB.apiVersion == "0.3.0-swiftdata")
    }
}

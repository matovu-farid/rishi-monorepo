@testable import rishi
import Foundation
import SwiftData
import Testing

@Suite("Book import additive migration", .serialized)
struct BookImportMigrationTests {
    @Test("pre-import store reopens with reading data and new import tables")
    func legacyStoreReopens() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("rishidb-pre-import.store")
        if ProcessInfo.processInfo.environment["RISHI_GENERATE_PRE_IMPORT_FIXTURE"] == "1" {
            let generatedFixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishidb-pre-import-fixture-generation.store")
            try Self.createPreImportFixture(at: generatedFixtureURL)
            return
        }
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            Issue.record("Missing checked-in pre-import store fixture at \(fixtureURL.path)")
            return
        }
        let runDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("rishidb-import-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        let runStoreURL = runDirectory.appendingPathComponent(fixtureURL.lastPathComponent)
        try FileManager.default.copyItem(at: fixtureURL, to: runStoreURL)

        let db = try RishiDB.makeStore(at: runStoreURL)
        let books = SwiftDataBookStore(dbStore: db)
        let positions = SwiftDataPositionStore(dbStore: db)
        let bookmarks = SwiftDataBookmarkStore(dbStore: db)
        let highlights = SwiftDataHighlightStore(dbStore: db)
        let legacyBookID = UUID(uuidString: "92964A4C-E3CE-4BE4-9F04-39811113B62D")!
        let legacyOwnerID = UUID(uuidString: "1CF0B77B-5A35-42ED-8F8B-0A89C351594E")!

        let restoredBook = try #require(await books.book(legacyBookID))
        #expect(restoredBook.userId == legacyOwnerID)
        #expect(restoredBook.title == "Pre-import fixture")
        #expect(restoredBook.fileURL == "books/pre-import.epub")
        #expect(try await positions.position(for: legacyBookID)?.locator == "epubcfi(/6/4!/4/2)")
        #expect(try await bookmarks.bookmarks(for: legacyBookID).map(\.label) == ["Legacy bookmark"])
        #expect(try await highlights.highlights(for: legacyBookID).map(\.text) == ["Legacy highlight"])

        let imports = SwiftDataBookImportPersistence(dbStore: db)
        let owner = UUID()
        let jobBook = Book(id: UUID(), userId: owner, title: "New schema row", formatType: .pdf, fileURL: "books/new.pdf")
        let promotionRevision = UUID()
        let destinationFileIdentifier = "fixture-managed"
        let job = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: owner, accountGeneration: .max, bookID: jobBook.id, attemptID: UUID()),
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([8, 3, 5]),
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 3, modificationDate: Date(timeIntervalSince1970: 5), fileIdentifier: nil, materializationRevision: UUID()),
            expectedSHA256: "ab12",
            expectedByteCount: 3,
            stagingRelativePath: "staging/new.part",
            destinationRelativePath: jobBook.fileURL,
            phase: .registered,
            destinationFileIdentifier: destinationFileIdentifier,
            promotionRevision: promotionRevision
        )
        try await imports.setAccountAuthorization(ownerID: owner, generation: .max)
        _ = try await imports.reserveRegistration(book: jobBook, job: job)
        #expect(try await imports.pendingMaterialization(bookID: jobBook.id, ownerID: owner) == job)
        #expect(try await imports.transition(token: job.token, from: .registered, to: .promoted))
        let fingerprint = BookFileFingerprint(
            bookID: jobBook.id,
            ownerID: owner,
            sha256: job.expectedSHA256,
            version: ManagedFileVersion(byteCount: job.expectedByteCount, modificationDate: Date(timeIntervalSince1970: 6), fileIdentifier: destinationFileIdentifier, materializationRevision: promotionRevision)
        )
        let mismatch = BookFileFingerprint(
            bookID: jobBook.id,
            ownerID: owner,
            sha256: job.expectedSHA256,
            version: ManagedFileVersion(byteCount: job.expectedByteCount, modificationDate: fingerprint.version.modificationDate, fileIdentifier: "different-file", materializationRevision: promotionRevision)
        )
        #expect(try await imports.commitManaged(token: job.token, fingerprint: mismatch) == false)
        #expect(try await imports.commitManaged(token: job.token, fingerprint: fingerprint))
        #expect(try await imports.fingerprint(bookID: jobBook.id, ownerID: owner) == fingerprint)
        #expect(try await db.read { context in
            try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).count
        } == 1)
        #expect(try await db.read { context in
            try context.fetch(FetchDescriptor<AccountMutationAuthorizationEntity>()).count
        } == 1)
        try await db.purgeAll()
        #expect(try await books.book(legacyBookID) == nil)
        #expect(try await db.read { context in
            (try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).count,
             try context.fetch(FetchDescriptor<AccountMutationAuthorizationEntity>()).count,
             try context.fetch(FetchDescriptor<PendingBookMaterializationEntity>()).count,
             try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).count)
        } == (0, 0, 0, 0))
    }

    private static func createPreImportFixture(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldSchema = Schema([
            BookEntity.self,
            PositionEntity.self,
            HighlightEntity.self,
            BookmarkEntity.self,
            ConversationEntity.self,
            MessageEntity.self,
            UserEntity.self,
            SyncMetadataEntity.self,
            ChapterIndexEntity.self,
            ChapterSummaryEntity.self,
        ])
        let container = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(url: url)])
        let context = ModelContext(container)
        let bookID = UUID(uuidString: "92964A4C-E3CE-4BE4-9F04-39811113B62D")!
        let ownerID = UUID(uuidString: "1CF0B77B-5A35-42ED-8F8B-0A89C351594E")!
        let positionID = UUID(uuidString: "E3A5C1BC-212A-4EF2-B9A7-F23F6D5C2F29")!
        let bookmarkID = UUID(uuidString: "EEBB7D69-1D80-47B4-8CA1-50D717BFBD84")!
        let highlightID = UUID(uuidString: "2BC82253-C511-4D23-BC91-E66EC00B0AE0")!
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(BookEntity(id: bookID, userId: ownerID, title: "Pre-import fixture", author: "Fixture Author", formatTypeRawValue: BookFormat.epub.rawValue, addedAt: addedAt, openedAt: nil, fileURL: "books/pre-import.epub", coverPath: nil, positionId: positionID, conversationId: nil))
        context.insert(PositionEntity(id: positionID, bookId: bookID, locator: "epubcfi(/6/4!/4/2)", percentComplete: 0.25, updatedAt: addedAt))
        context.insert(BookmarkEntity(id: bookmarkID, bookId: bookID, locator: "legacy-locator", label: "Legacy bookmark", snippet: "saved passage", createdAt: addedAt))
        context.insert(HighlightEntity(id: highlightID, bookId: bookID, locatorStart: "start", locatorEnd: "end", colorRawValue: HighlightColor.yellow.rawValue, text: "Legacy highlight", note: "keep me", createdAt: addedAt))
        try context.save()
    }

}

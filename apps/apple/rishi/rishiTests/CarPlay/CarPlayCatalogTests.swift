@testable import rishi
import Foundation
import Testing

@Suite("CarPlay catalog")
struct CarPlayCatalogTests {
    private let currentUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("catalog excludes unsupported formats and other users")
    func filtersToPlayableCurrentUserBooks() {
        let epub = makeBook("000000000101", title: "Playable")
        let pdf = makeBook("000000000102", title: "PDF", format: .pdf)
        let otherUserEPUB = makeBook("000000000103", userID: otherUserID, title: "Other User")

        let snapshot = CarPlayCatalog.project(
            currentUserID: currentUserID,
            books: [epub, pdf, otherUserEPUB],
            positions: [
                Position(bookId: epub.id, locator: "epubcfi(/6/2)", percentComplete: 0.4),
                Position(bookId: pdf.id, locator: "page:2", percentComplete: 0.6),
                Position(bookId: otherUserEPUB.id, locator: "epubcfi(/6/2)", percentComplete: 0.8)
            ],
            perSectionCap: 10
        )

        #expect(snapshot.sections.map(\.kind) == [.continueListening, .library])
        #expect(snapshot.sections[0].rows.map(\.id) == [epub.id])
        #expect(snapshot.sections[1].rows.map(\.id) == [epub.id])
    }

    @Test("continue listening is newest position first and library is title sorted")
    func sortsSectionsDeterministically() {
        let newest = makeBook("000000000201", title: "Newest")
        let older = makeBook("000000000202", title: "Older")
        let alpha = makeBook("000000000203", title: "alpha")
        let sameLowerID = makeBook("000000000204", title: "Same")
        let sameHigherID = makeBook("000000000205", title: "same")
        let zulu = makeBook("000000000206", title: "Zulu")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = CarPlayCatalog.project(
            currentUserID: currentUserID,
            books: [zulu, sameHigherID, older, alpha, newest, sameLowerID],
            positions: [
                Position(bookId: newest.id, locator: "new", percentComplete: 0.5,
                         updatedAt: baseDate.addingTimeInterval(20)),
                Position(bookId: older.id, locator: "old", percentComplete: 0.5,
                         updatedAt: baseDate.addingTimeInterval(10)),
                Position(bookId: alpha.id, locator: "start", percentComplete: 0),
            ],
            perSectionCap: 10
        )

        #expect(snapshot.sections.map(\.kind) == [.continueListening, .library])
        #expect(snapshot.sections[0].rows.map(\.id) == [newest.id, older.id])
        #expect(snapshot.sections[1].rows.map(\.id) == [
            alpha.id, sameLowerID.id, sameHigherID.id, newest.id, older.id, zulu.id
        ])
    }

    @Test("catalog preserves cover data on both sections and allows missing artwork")
    func preservesCoverDataAcrossSections() {
        let inProgress = makeBook("000000000207", title: "In Progress")
        let missingArtwork = makeBook("000000000208", title: "Missing Artwork")
        let coverData = Data([1, 2, 3])

        let snapshot = CarPlayCatalog.project(
            currentUserID: currentUserID,
            books: [inProgress, missingArtwork],
            positions: [
                Position(bookId: inProgress.id, locator: "start", percentComplete: 0.5)
            ],
            coverDataByBookID: [inProgress.id: coverData],
            perSectionCap: 10
        )

        #expect(snapshot.sections[0].rows.first(where: { $0.id == inProgress.id })?.coverData == coverData)
        #expect(snapshot.sections[1].rows.first(where: { $0.id == inProgress.id })?.coverData == coverData)
        #expect(snapshot.sections[1].rows.first(where: { $0.id == missingArtwork.id })?.coverData == nil)
    }

    @Test("book row display detail includes author and completion")
    func displaysAuthorAndCompletion() {
        let row = CarPlayBookRow(
            id: UUID(),
            title: "Book",
            author: "Author",
            percentComplete: 0.42
        )

        #expect(row.displayDetail == "Author · 42% complete")
    }

    @Test("book row display detail is absent without author or completion")
    func omitsDisplayDetailWithoutAuthorOrCompletion() {
        let row = CarPlayBookRow(id: UUID(), title: "Book", author: nil, percentComplete: nil)

        #expect(row.displayDetail == nil)
    }

    @Test("book row display detail includes completion without author")
    func displaysCompletionWithoutAuthor() {
        let row = CarPlayBookRow(id: UUID(), title: "Book", author: nil, percentComplete: 0.42)

        #expect(row.displayDetail == "42% complete")
    }

    @Test("cover reader rejects corrupt bytes")
    func rejectsCorruptCoverBytes() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("carplay-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 1, 2, 3]).write(to: url)

        #expect(CarPlayCoverReader.read(from: url) == nil)
    }

    @Test("cover reader rejects files larger than 4 MiB")
    func rejectsOversizedCover() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("carplay-oversized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(to: url)

        #expect(CarPlayCoverReader.read(from: url) == nil)
    }

    @Test("cover reader accepts a valid small image")
    func acceptsValidSmallImage() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("carplay-valid-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let imageData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try imageData.write(to: url)

        #expect(CarPlayCoverReader.read(from: url) != nil)
    }

    @Test("catalog caps each section for vehicle display")
    func capsRows() {
        let books = (1...4).map { index in
            makeBook(String(format: "0000000003%02d", index), title: "Book \(index)")
        }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let positions = books.enumerated().map { index, book in
            Position(
                bookId: book.id,
                locator: "position-\(index)",
                percentComplete: 0.25,
                updatedAt: baseDate.addingTimeInterval(Double(index))
            )
        }

        let snapshot = CarPlayCatalog.project(
            currentUserID: currentUserID,
            books: books,
            positions: positions,
            perSectionCap: 2
        )

        #expect(snapshot.sections[0].rows.map(\.id) == [books[3].id, books[2].id])
        #expect(snapshot.sections[1].rows.map(\.id) == [books[0].id, books[1].id])
        #expect(snapshot.sections.allSatisfy { $0.rows.count <= 2 })
    }

    @Test("empty positions do not create continue listening rows")
    func omitsUnstartedBooks() {
        let unstarted = makeBook("000000000401", title: "Unstarted")
        let noPosition = makeBook("000000000402", title: "No Position")

        let snapshot = CarPlayCatalog.project(
            currentUserID: currentUserID,
            books: [unstarted, noPosition],
            positions: [Position(bookId: unstarted.id, locator: "start", percentComplete: 0)],
            perSectionCap: 10
        )

        #expect(snapshot.sections[0].rows.isEmpty)
        #expect(snapshot.sections[1].rows.map(\.id) == [noPosition.id, unstarted.id])
    }

    private func makeBook(
        _ id: String,
        userID: UserID? = nil,
        title: String,
        format: BookFormat = .epub
    ) -> Book {
        Book(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(id)")!,
            userId: userID ?? currentUserID,
            title: title,
            formatType: format,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: "books/\(id).\(format.rawValue)"
        )
    }
}

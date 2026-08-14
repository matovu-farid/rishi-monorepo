import Foundation
import ImageIO

internal enum CarPlayCoverReader {
    private enum Limits {
        static let maxByteCount = 4 * 1024 * 1024
        static let maxPixelCount = 8_000_000
    }

    static func read(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: Limits.maxByteCount + 1) ?? Data()
        } catch {
            return nil
        }

        guard data.count <= Limits.maxByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
              width > 0,
              height > 0,
              width <= UInt64(Limits.maxPixelCount) / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0,
              UInt64(image.width) <= UInt64(Limits.maxPixelCount) / UInt64(image.height)
        else {
            return nil
        }

        return data
    }
}

public enum CarPlayCatalogSectionKind: String, Sendable, Equatable {
    case continueListening
    case library
}

public struct CarPlayBookRow: Sendable, Equatable, Identifiable {
    public let id: BookID
    public let title: String
    public let author: String?
    public let percentComplete: Double?
    public let coverData: Data?

    public var displayDetail: String? {
        var components: [String] = []
        if let author, !author.isEmpty {
            components.append(author)
        }
        if let percentComplete {
            components.append("\(Int(percentComplete * 100))% complete")
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    public init(id: BookID, title: String, percentComplete: Double?) {
        self.init(
            id: id,
            title: title,
            author: nil,
            percentComplete: percentComplete,
            coverData: nil
        )
    }

    public init(id: BookID, title: String, author: String?, percentComplete: Double?) {
        self.init(
            id: id,
            title: title,
            author: author,
            percentComplete: percentComplete,
            coverData: nil
        )
    }

    public init(
        id: BookID,
        title: String,
        author: String? = nil,
        percentComplete: Double? = nil,
        coverData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.percentComplete = percentComplete
        self.coverData = coverData
    }
}

public struct CarPlayCatalogSection: Sendable, Equatable, Identifiable {
    public let kind: CarPlayCatalogSectionKind
    public let rows: [CarPlayBookRow]

    public var id: CarPlayCatalogSectionKind { kind }

    public init(kind: CarPlayCatalogSectionKind, rows: [CarPlayBookRow]) {
        self.kind = kind
        self.rows = rows
    }
}

public struct CarPlayCatalogSnapshot: Sendable, Equatable {
    public let sections: [CarPlayCatalogSection]

    public init(sections: [CarPlayCatalogSection]) {
        self.sections = sections
    }
}

public struct CarPlayAccountSnapshot: Sendable, Equatable {
    public let userID: UserID
    public let generation: UInt64

    public init(userID: UserID, generation: UInt64) {
        self.userID = userID
        self.generation = generation
    }
}

public enum CarPlayCatalog {
    public static func project(
        currentUserID: UserID,
        books: [Book],
        positions: [Position],
        perSectionCap: Int,
        coverDataByBookID: [BookID: Data] = [:]
    ) -> CarPlayCatalogSnapshot {
        let playableBooks = books.filter { book in
            book.userId == currentUserID && book.formatType == .epub
        }
        let playableBookIDs = Set(playableBooks.map(\.id))
        let latestPositions = latestPositions(
            positions,
            for: playableBookIDs
        )

        let continueListening = playableBooks.compactMap { book -> (Book, Position)? in
            guard let position = latestPositions[book.id],
                  position.percentComplete > 0,
                  position.percentComplete < 1
            else {
                return nil
            }
            return (book, position)
        }
        .sorted { lhs, rhs in
            if lhs.1.updatedAt != rhs.1.updatedAt {
                return lhs.1.updatedAt > rhs.1.updatedAt
            }
            return lhs.0.id.uuidString < rhs.0.id.uuidString
        }
        .map { book, position in
            CarPlayBookRow(
                id: book.id,
                title: book.title,
                author: book.author,
                percentComplete: position.percentComplete,
                coverData: coverDataByBookID[book.id]
            )
        }

        let library = playableBooks
            .sorted { lhs, rhs in
                switch lhs.title.localizedCaseInsensitiveCompare(rhs.title) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
            .map { book in
                CarPlayBookRow(
                    id: book.id,
                    title: book.title,
                    author: book.author,
                    percentComplete: latestPositions[book.id]?.percentComplete,
                    coverData: coverDataByBookID[book.id]
                )
            }

        return CarPlayCatalogSnapshot(sections: [
            CarPlayCatalogSection(
                kind: .continueListening,
                rows: capped(continueListening, at: perSectionCap)
            ),
            CarPlayCatalogSection(
                kind: .library,
                rows: capped(library, at: perSectionCap)
            )
        ])
    }

    private static func latestPositions(
        _ positions: [Position],
        for bookIDs: Set<BookID>
    ) -> [BookID: Position] {
        var latest: [BookID: Position] = [:]

        for position in positions where bookIDs.contains(position.bookId) {
            guard let current = latest[position.bookId] else {
                latest[position.bookId] = position
                continue
            }

            if position.updatedAt > current.updatedAt ||
                (position.updatedAt == current.updatedAt &&
                    position.id.uuidString < current.id.uuidString)
            {
                latest[position.bookId] = position
            }
        }

        return latest
    }

    private static func capped<T>(_ values: [T], at cap: Int) -> [T] {
        guard cap > 0 else { return [] }
        return Array(values.prefix(cap))
    }
}

@MainActor
public final class CarPlayCatalogLoader {
    private let bookStore: any BookStore
    private let positionStore: any PositionStore
    private let bookFileStorage: BookFileStorage
    private let accountSnapshot: @MainActor @Sendable () -> CarPlayAccountSnapshot?

    public init(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        bookFileStorage: BookFileStorage,
        accountSnapshot: @escaping @MainActor @Sendable () -> CarPlayAccountSnapshot?
    ) {
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.bookFileStorage = bookFileStorage
        self.accountSnapshot = accountSnapshot
    }

    /// Returns nil when the account changes or signs out while the snapshot is loading.
    public func load(perSectionCap: Int) async throws -> CarPlayCatalogSnapshot? {
        guard let captured = accountSnapshot() else { return nil }
        let books = try await bookStore.books(for: captured.userID)
        guard accountSnapshot() == captured else { return nil }

        let localBooks = await Self.localBooks(
            from: books,
            storage: bookFileStorage
        )
        guard accountSnapshot() == captured else { return nil }

        var positions: [Position] = []
        positions.reserveCapacity(localBooks.count)
        let positionLoader = PositionLoader(positionStore: positionStore)
        let batchSize = 8
        for batchStart in stride(from: 0, to: localBooks.count, by: batchSize) {
            guard accountSnapshot() == captured else { return nil }
            let batchEnd = min(batchStart + batchSize, localBooks.count)
            let batch = Array(localBooks[batchStart..<batchEnd])
            let batchPositions = await positionLoader.positions(for: batch)
            positions.append(contentsOf: batchPositions.values)
            guard accountSnapshot() == captured else { return nil }
        }

        guard accountSnapshot() == captured else { return nil }
        let projected = CarPlayCatalog.project(
            currentUserID: captured.userID,
            books: localBooks,
            positions: positions,
            perSectionCap: perSectionCap
        )
        guard accountSnapshot() == captured else { return nil }

        let visibleBookIDs = Set(
            projected.sections.flatMap { section in section.rows.map(\.id) }
        )
        let visibleBooks = localBooks.filter { visibleBookIDs.contains($0.id) }
        let coverDataByBookID = await Self.readCachedCoverData(
            for: visibleBooks,
            storage: bookFileStorage
        )
        guard accountSnapshot() == captured else { return nil }

        let sections = projected.sections.map { section in
            CarPlayCatalogSection(
                kind: section.kind,
                rows: section.rows.map { row in
                    CarPlayBookRow(
                        id: row.id,
                        title: row.title,
                        author: row.author,
                        percentComplete: row.percentComplete,
                        coverData: coverDataByBookID[row.id]
                    )
                }
            )
        }

        guard accountSnapshot() == captured else { return nil }
        return CarPlayCatalogSnapshot(sections: sections)
    }

    private nonisolated static func localBooks(
        from books: [Book],
        storage: BookFileStorage
    ) async -> [Book] {
        await Task.detached(priority: .utility) {
            books.filter { book in
                book.formatType == .epub &&
                FileManager.default.fileExists(
                    atPath: storage.absoluteFileURL(for: book).path
                )
            }
        }.value
    }

    private nonisolated static func readCachedCoverData(
        for books: [Book],
        storage: BookFileStorage
    ) async -> [BookID: Data] {
        await Task.detached(priority: .utility) {
            await withTaskGroup(of: (BookID, Data?).self) { group in
                for book in books {
                    group.addTask {
                        guard let coverURL = storage.cachedCoverURLIfFresh(for: book) else {
                            return (book.id, nil)
                        }
                        return (book.id, CarPlayCoverReader.read(from: coverURL))
                    }
                }

                var coverDataByBookID: [BookID: Data] = [:]
                for await (bookID, coverData) in group {
                    if let coverData {
                        coverDataByBookID[bookID] = coverData
                    }
                }
                return coverDataByBookID
            }
        }.value
    }

}

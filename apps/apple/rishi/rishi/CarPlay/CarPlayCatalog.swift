import Foundation

public enum CarPlayCatalogSectionKind: String, Sendable, Equatable {
    case continueListening
    case library
}

public struct CarPlayBookRow: Sendable, Equatable, Identifiable {
    public let id: BookID
    public let title: String
    public let author: String?
    public let percentComplete: Double?

    public init(id: BookID, title: String, percentComplete: Double?) {
        self.init(id: id, title: title, author: nil, percentComplete: percentComplete)
    }

    public init(id: BookID, title: String, author: String?, percentComplete: Double?) {
        self.id = id
        self.title = title
        self.author = author
        self.percentComplete = percentComplete
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
        perSectionCap: Int
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
                percentComplete: position.percentComplete
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
                    percentComplete: latestPositions[book.id]?.percentComplete
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

        let localBooks = books.filter { book in
            book.formatType == .epub &&
            FileManager.default.fileExists(
                atPath: bookFileStorage.absoluteFileURL(for: book).path
            )
        }
        guard accountSnapshot() == captured else { return nil }

        var positions: [Position] = []
        positions.reserveCapacity(localBooks.count)
        for book in localBooks {
            if let position = try await positionStore.position(for: book.id) {
                positions.append(position)
            }
            guard accountSnapshot() == captured else { return nil }
        }

        guard accountSnapshot() == captured else { return nil }
        return CarPlayCatalog.project(
            currentUserID: captured.userID,
            books: localBooks,
            positions: positions,
            perSectionCap: perSectionCap
        )
    }
}

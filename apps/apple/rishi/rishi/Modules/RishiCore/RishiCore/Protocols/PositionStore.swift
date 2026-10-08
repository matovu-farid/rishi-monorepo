import Foundation

public protocol PositionStore: Sendable {
    func position(for bookId: BookID) async throws -> Position?
    func positions(for bookIDs: Set<BookID>) async throws -> [BookID: Position]
    func upsert(_ position: Position) async throws
    func delete(_ id: PositionID) async throws
}

public extension PositionStore {
    /// Compatibility path for stores that only implement single-book reads.
    /// Concrete stores can override this to batch their persistence work.
    func positions(for bookIDs: Set<BookID>) async throws -> [BookID: Position] {
        await withTaskGroup(of: (BookID, Position?).self) { group in
            for bookID in bookIDs {
                group.addTask { (bookID, try? await position(for: bookID)) }
            }
            var result: [BookID: Position] = [:]
            for await (bookID, value) in group {
                if let value { result[bookID] = value }
            }
            return result
        }
    }
}

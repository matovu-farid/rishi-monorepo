import Foundation
import RishiCore

/// Loads reading positions for a set of books, fanning out the per-book
/// `PositionStore` reads concurrently.
///
/// Extracted from `LibraryViewModel.refresh()` (Plan 34-11) so the
/// view-model no longer performs storage fan-out inline. `PositionStore` is
/// `Sendable` + nonisolated, so each spawned task runs off the MainActor;
/// the only hop back is for the caller's final state assignment. The
/// `PositionStore` protocol is unchanged — the fan-out lives here.
public struct PositionLoader: Sendable {

    private let positionStore: any PositionStore

    public init(positionStore: any PositionStore) {
        self.positionStore = positionStore
    }

    /// Fans out `positionStore.position(for:)` across `books` concurrently
    /// and returns the `BookID -> Position` map. Books with no saved
    /// position (or a read error) are omitted.
    public func positions(for books: [Book]) async -> [BookID: Position] {
        await withTaskGroup(of: (BookID, Position?).self) { group in
            for book in books {
                group.addTask { [positionStore] in
                    let p = try? await positionStore.position(for: book.id)
                    return (book.id, p)
                }
            }
            var out: [BookID: Position] = [:]
            for await (id, position) in group {
                if let position { out[id] = position }
            }
            return out
        }
    }
}

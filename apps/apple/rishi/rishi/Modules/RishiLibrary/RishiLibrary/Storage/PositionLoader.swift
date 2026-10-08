import Foundation


/// Loads reading positions for a set of books in one store operation.
///
/// Extracted from `LibraryViewModel.refresh()` (Plan 34-11) so the
/// view-model no longer performs storage work inline. Concrete persistence
/// stores can perform one actor-confined batch read; compatibility stores use
/// the protocol's default implementation.
public struct PositionLoader: Sendable {

    private let positionStore: any PositionStore

    public init(positionStore: any PositionStore) {
        self.positionStore = positionStore
    }

    /// Returns the newest saved position per requested book. Missing positions
    /// and read errors are omitted, matching the previous best-effort behavior.
    public func positions(for books: [Book]) async -> [BookID: Position] {
        let requestedIDs = Set(books.map(\.id))
        do {
            let positions = try await positionStore.positions(for: requestedIDs)
            return positions.filter { requestedIDs.contains($0.key) }
        }
        catch { return [:] }
    }
}

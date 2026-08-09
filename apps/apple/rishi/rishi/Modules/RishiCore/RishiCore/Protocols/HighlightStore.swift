import Foundation

public protocol HighlightStore: Sendable {
    func highlights(for bookId: BookID) async throws -> [Highlight]
    func highlight(_ id: HighlightID) async throws -> Highlight?
    func upsert(_ highlight: Highlight) async throws
    func delete(_ id: HighlightID) async throws
    func deleteIfUnchanged(_ id: HighlightID, matching expected: Highlight?) async throws -> Bool
}

public extension HighlightStore {
    func deleteIfUnchanged(_ id: HighlightID, matching expected: Highlight?) async throws -> Bool {
        guard try await highlight(id) == expected else { return false }
        try await delete(id)
        return true
    }
}

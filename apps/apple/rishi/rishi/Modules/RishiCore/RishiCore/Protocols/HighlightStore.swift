import Foundation

public protocol HighlightStore: Sendable {
    func highlights(for bookId: BookID) async throws -> [Highlight]
    func highlight(_ id: HighlightID) async throws -> Highlight?
    func upsert(_ highlight: Highlight) async throws
    func delete(_ id: HighlightID) async throws
}

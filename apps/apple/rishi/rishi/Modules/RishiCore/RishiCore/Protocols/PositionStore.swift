import Foundation

public protocol PositionStore: Sendable {
    func position(for bookId: BookID) async throws -> Position?
    func upsert(_ position: Position) async throws
    func delete(_ id: PositionID) async throws
}

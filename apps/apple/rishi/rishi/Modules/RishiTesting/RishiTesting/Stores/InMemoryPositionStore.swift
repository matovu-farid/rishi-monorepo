import Foundation


public actor InMemoryPositionStore: PositionStore {
    private var storage: [BookID: Position] = [:]

    public init(initial: [Position] = []) {
        for p in initial { storage[p.bookId] = p }
    }

    public func position(for bookId: BookID) async throws -> Position? {
        storage[bookId]
    }

    public func upsert(_ position: Position) async throws {
        storage[position.bookId] = position
    }

    public func delete(_ id: PositionID) async throws {
        if let key = storage.first(where: { $0.value.id == id })?.key {
            storage.removeValue(forKey: key)
        }
    }
}

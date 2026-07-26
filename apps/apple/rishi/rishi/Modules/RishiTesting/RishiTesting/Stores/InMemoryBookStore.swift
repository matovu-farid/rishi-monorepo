import Foundation


public actor InMemoryBookStore: BookStore {
    private var storage: [BookID: Book] = [:]

    public init(initial: [Book] = []) {
        for b in initial { storage[b.id] = b }
    }

    public func books(for userId: UserID) async throws -> [Book] {
        storage.values
            .filter { $0.userId == userId }
            .sorted { $0.addedAt < $1.addedAt }
    }

    public func book(_ id: BookID) async throws -> Book? {
        storage[id]
    }

    public func upsert(_ book: Book) async throws {
        storage[book.id] = book
    }

    public func delete(_ id: BookID) async throws {
        storage.removeValue(forKey: id)
    }

    /// Test affordance: snapshot the current storage map.
    public func snapshot() -> [Book] {
        Array(storage.values)
    }
}

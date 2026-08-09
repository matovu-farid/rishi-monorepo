import Foundation

public protocol BookStore: Sendable {
    func books(for userId: UserID) async throws -> [Book]
    func book(_ id: BookID) async throws -> Book?
    func upsert(_ book: Book) async throws
    func delete(_ id: BookID) async throws
    func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool
}

public extension BookStore {
    func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool {
        guard try await book(id) == expected else { return false }
        try await delete(id)
        return true
    }
}

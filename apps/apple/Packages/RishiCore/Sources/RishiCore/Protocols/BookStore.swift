import Foundation

public protocol BookStore: Sendable {
    func books(for userId: UserID) async throws -> [Book]
    func book(_ id: BookID) async throws -> Book?
    func upsert(_ book: Book) async throws
    func delete(_ id: BookID) async throws
}

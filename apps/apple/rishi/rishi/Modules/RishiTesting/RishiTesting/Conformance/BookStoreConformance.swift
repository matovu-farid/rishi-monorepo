import Foundation


/// Run a behavioral battery against any `BookStore` implementation.
/// Used by both InMemoryBookStore's own tests and Phase 2 GRDB-backed
/// implementations to ensure both pass the same contract.
///
/// Throws `RishiTestingError.expected(...)` on the first violation.
public func assertBookStoreConformance(_ store: any BookStore) async throws {
    let userA = UUID()
    let userB = UUID()

    // 1) Initially empty for any user
    let initialA = try await store.books(for: userA)
    guard initialA.isEmpty else {
        throw RishiTestingError.expected("books(for: userA) initially empty, got \(initialA.count)")
    }

    // 2) Upsert round-trips
    let book1 = Book.fixture(userId: userA, title: "First")
    try await store.upsert(book1)
    let after1 = try await store.book(book1.id)
    guard after1 == book1 else {
        throw RishiTestingError.expected("book(_:) returned \(String(describing: after1)) expected \(book1)")
    }

    // 3) Idempotent upsert (no duplicates)
    try await store.upsert(book1)
    let userABooks = try await store.books(for: userA)
    guard userABooks.count == 1 else {
        throw RishiTestingError.expected("re-upsert produced \(userABooks.count) rows, expected 1")
    }

    // 4) User scoping
    let book2 = Book.fixture(userId: userB, title: "Second")
    try await store.upsert(book2)
    let userAAfterB = try await store.books(for: userA)
    let userBAfterB = try await store.books(for: userB)
    guard userAAfterB.count == 1, userBAfterB.count == 1 else {
        throw RishiTestingError.expected("userA=\(userAAfterB.count) userB=\(userBAfterB.count); expected 1 each")
    }

    // 5) Delete-then-fetch returns nil
    try await store.delete(book1.id)
    let afterDelete = try await store.book(book1.id)
    guard afterDelete == nil else {
        throw RishiTestingError.expected("book(_:) after delete returned non-nil")
    }
}

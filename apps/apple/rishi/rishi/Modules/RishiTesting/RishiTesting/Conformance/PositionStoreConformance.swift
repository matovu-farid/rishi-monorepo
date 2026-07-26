import Foundation


public func assertPositionStoreConformance(_ store: any PositionStore) async throws {
    let bookA = UUID()
    let bookB = UUID()

    let initial = try await store.position(for: bookA)
    guard initial == nil else {
        throw RishiTestingError.expected("position initially nil")
    }

    let p1 = Position.fixture(bookId: bookA, locator: "loc-1", percentComplete: 0.2)
    try await store.upsert(p1)
    let fetched1 = try await store.position(for: bookA)
    guard fetched1 == p1 else {
        throw RishiTestingError.expected("position round-trip failed")
    }

    // Upsert SAME bookId → replaces, does not duplicate
    let p1b = Position.fixture(id: p1.id, bookId: bookA, locator: "loc-1b", percentComplete: 0.3)
    try await store.upsert(p1b)
    let fetched1b = try await store.position(for: bookA)
    guard fetched1b?.locator == "loc-1b", fetched1b?.percentComplete == 0.3 else {
        throw RishiTestingError.expected("position upsert did not update")
    }

    // Scoping
    let p2 = Position.fixture(bookId: bookB, locator: "loc-2")
    try await store.upsert(p2)
    let stillA = try await store.position(for: bookA)
    guard stillA?.locator == "loc-1b" else {
        throw RishiTestingError.expected("position scoping leaked")
    }

    try await store.delete(p1.id)
    let afterDelete = try await store.position(for: bookA)
    guard afterDelete == nil else {
        throw RishiTestingError.expected("position not deleted")
    }
}

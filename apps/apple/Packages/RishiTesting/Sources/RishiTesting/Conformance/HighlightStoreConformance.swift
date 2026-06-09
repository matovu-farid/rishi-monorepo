import Foundation
import RishiCore

public func assertHighlightStoreConformance(_ store: any HighlightStore) async throws {
    let bookA = UUID()
    let bookB = UUID()

    let empty = try await store.highlights(for: bookA)
    guard empty.isEmpty else {
        throw RishiTestingError.expected("highlights initially empty, got \(empty.count)")
    }

    let h1 = Highlight.fixture(bookId: bookA, color: .yellow, text: "alpha")
    try await store.upsert(h1)
    let got = try await store.highlight(h1.id)
    guard got == h1 else {
        throw RishiTestingError.expected("highlight(_:) mismatch")
    }

    try await store.upsert(h1) // idempotent
    let aOnly = try await store.highlights(for: bookA)
    guard aOnly.count == 1 else {
        throw RishiTestingError.expected("re-upsert produced \(aOnly.count) rows")
    }

    let h2 = Highlight.fixture(bookId: bookB, color: .green, text: "beta")
    try await store.upsert(h2)
    let bOnly = try await store.highlights(for: bookB)
    guard bOnly.count == 1, bOnly.first?.color == .green else {
        throw RishiTestingError.expected("book scoping failed")
    }

    try await store.delete(h1.id)
    let postDelete = try await store.highlight(h1.id)
    guard postDelete == nil else {
        throw RishiTestingError.expected("highlight not deleted")
    }
}

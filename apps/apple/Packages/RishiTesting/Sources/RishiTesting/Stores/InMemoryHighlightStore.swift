import Foundation
import RishiCore

public actor InMemoryHighlightStore: HighlightStore {
    private var storage: [HighlightID: Highlight] = [:]

    public init(initial: [Highlight] = []) {
        for h in initial { storage[h.id] = h }
    }

    public func highlights(for bookId: BookID) async throws -> [Highlight] {
        storage.values
            .filter { $0.bookId == bookId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func highlight(_ id: HighlightID) async throws -> Highlight? {
        storage[id]
    }

    public func upsert(_ highlight: Highlight) async throws {
        storage[highlight.id] = highlight
    }

    public func delete(_ id: HighlightID) async throws {
        storage.removeValue(forKey: id)
    }
}

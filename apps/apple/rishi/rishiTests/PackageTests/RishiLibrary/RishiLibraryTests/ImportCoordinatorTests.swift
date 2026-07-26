@testable import rishi
import Foundation
import Testing




@Suite("ImportCoordinator")
struct ImportCoordinatorTests {

    static func makeRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportCoordinator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("filterSupported keeps only known extensions (case-insensitive)")
    func filtersExtensions() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.EPUB"),
            URL(fileURLWithPath: "/tmp/c.mobi"),
            URL(fileURLWithPath: "/tmp/d.azw3"),
            URL(fileURLWithPath: "/tmp/e.txt"),
            URL(fileURLWithPath: "/tmp/f"),
        ]
        let kept = ImportCoordinator.filterSupported(urls).map { $0.lastPathComponent }
        #expect(kept == ["a.pdf", "b.EPUB", "c.mobi", "d.azw3"])
    }

    @Test("importBooks forwards each supported URL to BookFileStorage")
    func forwardsToStorage() async throws {
        let root = Self.makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let userId = UUID()
        let coordinator = ImportCoordinator(storage: storage) { userId }

        let a = root.appendingPathComponent("a.pdf")
        try Data([0]).write(to: a)
        let b = root.appendingPathComponent("b.txt")
        try Data([0]).write(to: b)

        let outcomes = await coordinator.importBooks([a, b])
        // 'b.txt' filtered out → only one outcome.
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.book != nil)
        #expect(outcomes.first?.error == nil)

        let stored = try await store.books(for: userId)
        #expect(stored.count == 1)
    }

    @Test("Missing user yields outcomes flagged 'no_user' with no DB writes")
    func noUserShortCircuits() async throws {
        let root = Self.makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let coordinator = ImportCoordinator(storage: storage) { nil }

        let a = root.appendingPathComponent("a.pdf")
        try Data([0]).write(to: a)

        let outcomes = await coordinator.importBooks([a])
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == "no_user")
        #expect(outcomes.first?.book == nil)

        // No book row inserted.
        let snapshot = await store.snapshot()
        #expect(snapshot.isEmpty)
    }

    @Test("allowedExtensions matches BookFormat.allCases raw values")
    func allowListMatchesBookFormat() {
        let formatExts = Set(BookFormat.allCases.map { $0.rawValue.lowercased() })
        #expect(ImportCoordinator.allowedExtensions == formatExts)
    }
}

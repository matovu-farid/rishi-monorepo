@testable import rishi
import Testing
import Foundation





@Suite("SampleBookInstaller")
struct SampleBookInstallerTests {


    @Test("First run: copies alice.epub from bundle into the library")
    func firstRunInstalls() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store,
                                      coverExtractors: ["epub": EpubCoverExtractor()])
        let defaults = makeDefaults()
        let installer = SampleBookInstaller(storage: storage, defaults: defaults)

        let userId = UUID()
        let book = await installer.installIfNeeded(ownerId: userId)
        #expect(book != nil)
        #expect(book?.formatType == .epub)
        #expect(defaults.bool(forKey: SampleBookInstaller.defaultsKey))
    }

    @Test("Second run: no-op (idempotent)")
    func secondRunIdempotent() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let defaults = makeDefaults()
        let installer = SampleBookInstaller(storage: storage, defaults: defaults)
        let userId = UUID()
        _ = await installer.installIfNeeded(ownerId: userId)
        let booksAfterFirst = try await store.books(for: userId).count
        let secondBook = await installer.installIfNeeded(ownerId: userId)
        let booksAfterSecond = try await store.books(for: userId).count
        #expect(secondBook == nil)
        #expect(booksAfterFirst == booksAfterSecond)
    }

    @Test("Missing resource is logged + nil-returned (not thrown)")
    func missingResourceGraceful() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let defaults = makeDefaults()
        // Force a bundle with no resources so the lookup fails.
        let installer = SampleBookInstaller(storage: storage, defaults: defaults,
                                            bundle: Bundle(for: NSObject.self))
        let book = await installer.installIfNeeded(ownerId: UUID())
        #expect(book == nil)
        #expect(!defaults.bool(forKey: SampleBookInstaller.defaultsKey))
    }
}

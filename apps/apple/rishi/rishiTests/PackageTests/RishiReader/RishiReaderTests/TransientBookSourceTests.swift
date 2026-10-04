@testable import rishi
import Foundation
import Testing

private final class ReaderSourceLifetimeProbe {}

@Suite("Transient reader source ownership", .serialized)
struct TransientBookSourceTests {
    @Test("reader view model keeps its source alive until the reader is released")
    func readerRetainsSourceLifetime() {
        var source: ReaderSourceLifetimeProbe? = ReaderSourceLifetimeProbe()
        weak var weakSource = source
        let book = Book(userId: UUID(), title: "Transient", formatType: .epub, fileURL: "/provider/book.epub")
        var reader: ReaderViewModel? = ReaderViewModel(
            book: book,
            userId: book.userId,
            documentURL: URL(fileURLWithPath: book.fileURL),
            positionStore: InMemoryPositionStore(),
            sourceLifetime: source
        )

        source = nil
        #expect(weakSource != nil)

        reader = nil
        #expect(weakSource == nil)
    }

    @Test("each reader observer receives source invalidation")
    func invalidationBroadcastsToReaderAndPlaybackObservers() async {
        let signal = BookSourceInvalidationSignal()
        var readerObserver = signal.stream.makeAsyncIterator()
        var playbackObserver = signal.stream.makeAsyncIterator()

        signal.invalidate()

        #expect(await readerObserver.next() != nil)
        #expect(await playbackObserver.next() != nil)
    }

    @Test("transient source bypasses UUID-parent EPUB unpack cache")
    func transientPolicyBypassesParentUUIDHeuristic() async throws {
        let fixture = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookID = UUID()
        let sourceDirectory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("alice.epub")
        try FileManager.default.copyItem(at: fixture, to: sourceURL)

        let cache = EPUBUnpackedCache(configuration: .init(rootDirectory: root.appendingPathComponent("unpacked", isDirectory: true)))
        let loader = PublicationLoader(
            unpackedCache: cache,
            cachePolicy: .transient
        )
        _ = try await loader.open(fileURL: sourceURL)

        #expect(await cache.didAttemptUnpackCount == 0)
    }
}

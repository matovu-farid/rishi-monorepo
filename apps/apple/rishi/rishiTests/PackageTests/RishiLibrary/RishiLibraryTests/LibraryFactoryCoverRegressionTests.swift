@testable import rishi
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@MainActor
@Suite("Library factory legacy cover regression")
struct LibraryFactoryCoverRegressionTests {
    private struct NoopExtractor: CoverExtractor {
        func extractCover(from fileURL: URL) async -> Data? { nil }
    }

    private actor ExtractorSpy: CoverExtractor {
        private var calls = 0
        private let payload: Data?
        init(payload: Data? = nil) { self.payload = payload }
        func extractCover(from fileURL: URL) async -> Data? { calls += 1; return payload }
        func callCount() -> Int { calls }
    }

    private struct Fixture {
        let db: RishiDBStore
        let store: SwiftDataBookStore
        let persistence: SwiftDataBookImportPersistence
        var storage: BookFileStorage
        let registry: BookSourceRegistry
        let root: URL
        let owner: UserID
        let generation: UInt64
        let generationState: MutableGenerationBox
    }

    private final class MutableGenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64
        init(_ value: UInt64) { stored = value }
        var value: UInt64 { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: UInt64) { lock.lock(); stored = value; lock.unlock() }
    }

    private actor BookLookupGate {
        private var openState = false
        private var entered = false
        private var openWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        private var enteredWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        func waitAtLookup() async {
            entered = true
            let waiting = enteredWaiters.values
            enteredWaiters.removeAll()
            waiting.forEach { $0.resume(returning: true) }
            if openState { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if openState { continuation.resume() }
                    else { openWaiters[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancelOpenWaiter(id) }
            }
        }
        func waitUntilEntered(timeoutMilliseconds: UInt64 = 5_000) async -> Bool {
            if entered { return true }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if entered { continuation.resume(returning: true) }
                    else {
                        enteredWaiters[id] = continuation
                        Task {
                            try? await Task.sleep(nanoseconds: timeoutMilliseconds * 1_000_000)
                            await self.timeoutEntryWaiter(id)
                        }
                    }
                }
            } onCancel: {
                Task { await self.timeoutEntryWaiter(id) }
            }
        }
        func open() {
            openState = true
            let waiting = openWaiters.values
            openWaiters.removeAll()
            waiting.forEach { $0.resume() }
        }
        private func cancelOpenWaiter(_ id: UUID) { openWaiters.removeValue(forKey: id)?.resume() }
        private func timeoutEntryWaiter(_ id: UUID) { enteredWaiters.removeValue(forKey: id)?.resume(returning: false) }
    }

    private actor GatedBookStore: BookStore {
        private let base: any BookStore
        private let gate: BookLookupGate
        private let pauseAtLookup: Int
        private var reads = 0
        private var hasPaused = false
        init(base: any BookStore, gate: BookLookupGate, pauseAtLookup: Int = 1) {
            self.base = base
            self.gate = gate
            self.pauseAtLookup = pauseAtLookup
        }
        func books(for userId: UserID) async throws -> [Book] { try await base.books(for: userId) }
        func book(_ id: BookID) async throws -> Book? {
            reads += 1
            if !hasPaused, reads == pauseAtLookup { hasPaused = true; await gate.waitAtLookup() }
            return try await base.book(id)
        }
        func upsert(_ book: Book) async throws { try await base.upsert(book) }
        func delete(_ id: BookID) async throws { try await base.delete(id) }
    }

    private func makeFixture(_ label: String, tombstonedBookID: BookID? = nil) throws -> Fixture {
        let root = URL.temporaryDirectory.appendingPathComponent("LibraryFactoryCover-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let store = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let owner = UUID()
        let generation: UInt64 = 91
        let generationState = MutableGenerationBox(generation)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generationState.value },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: ["epub": NoopExtractor()],
                                      isTombstoned: { $0 == tombstonedBookID })
        return Fixture(db: db, store: store, persistence: persistence, storage: storage, registry: registry,
                       root: root, owner: owner, generation: generation, generationState: generationState)
    }

    private func makePNG(width: Int = 3, height: Int = 5) throws -> Data {
        let data = NSMutableData()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func assertPublishedImage(_ url: URL?, width: Int = 3, height: Int = 5) throws {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("published cover URL must decode as an image")
            return
        }
        #expect(image.width == width)
        #expect(image.height == height)
    }

    private func makeViewModel(_ fixture: Fixture) -> LibraryViewModel {
        let identity = LibraryAccountIdentity(userID: fixture.owner, generation: fixture.generation)
        return LibraryViewModel.make(
            bookStore: fixture.store,
            userId: fixture.owner,
            importCoordinator: ImportCoordinator(storage: fixture.storage, currentUserId: { fixture.owner }),
            positionStore: InMemoryPositionStore(),
            bookFileStorage: fixture.storage,
            bookSourceRegistry: fixture.registry,
            currentAccountGeneration: { fixture.generationState.value },
            accountIdentity: identity,
            currentAccountIdentity: { identity }
        )
    }

    private func authorizeManagedSource(_ book: Book, in fixture: Fixture, at managedURL: URL) async throws {
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
        let bytes = try Data(contentsOf: managedURL)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: fixture.owner, sha256: digest, version: version)
        try await fixture.persistence.setAccountAuthorization(ownerID: fixture.owner, generation: fixture.generation)
        try await fixture.persistence.setBookReadingAuthorization(bookID: book.id, ownerID: fixture.owner, generation: fixture.generation,
                                                                  contentRevision: revision, tombstoned: false)
        #expect(try await fixture.persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: fixture.generation,
                                                                      expectedRelativePath: book.fileURL, expectedVersion: version))
        #expect(try await fixture.registry.managedSource(for: book) != nil)
    }

    @Test("factory publishes owned raw artwork for legacy row without fingerprints")
    func factoryPublishesRawCoverForLegacyRow() async throws {
        let fixture = try makeFixture("raw")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let relativeCoverPath = "Books/\(id.uuidString)/cover.png"
        let book = Book(id: id, userId: fixture.owner, title: "Legacy raw", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: relativeCoverPath)
        let coverURL = fixture.root.appendingPathComponent(relativeCoverPath)
        try FileManager.default.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePNG().write(to: coverURL)
        try await fixture.store.upsert(book)

        let vm = makeViewModel(fixture)
        await vm.refresh()
        await vm.waitForHydration()

        try assertPublishedImage(vm.coverURLs[book.id])
        #expect(try await fixture.registry.managedSource(for: book) == nil)
    }

    @Test("factory publishes a fresh thumbnail for legacy row with no coverPath")
    func factoryPublishesFreshThumbnailWithoutCoverPath() async throws {
        let fixture = try makeFixture("thumbnail")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let book = Book(id: id, userId: fixture.owner, title: "Legacy thumbnail", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: nil)
        let sourceURL = fixture.root.appendingPathComponent(relativeBookPath)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed book payload is not read".utf8).write(to: sourceURL)
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: sourceURL.path)
        let cacheDirectory = fixture.root.appendingPathComponent("Caches/book-covers", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try makePNG().write(to: cacheDirectory.appendingPathComponent("\(id.uuidString).heic"))
        try Data(String(pinned.timeIntervalSince1970).utf8).write(to: cacheDirectory.appendingPathComponent("\(id.uuidString).mtime"))
        try await fixture.store.upsert(book)

        let vm = makeViewModel(fixture)
        await vm.refresh()
        await vm.waitForHydration()

        try assertPublishedImage(vm.coverURLs[book.id])
        #expect(try await fixture.registry.managedSource(for: book) == nil)
    }

    @Test("authorized cold source still extracts and publishes a fresh cover")
    func authorizedColdSourceKeepsExtractionPath() async throws {
        var fixture = try makeFixture("authorized-cold")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let book = Book(id: id, userId: fixture.owner, title: "Authorized cold source", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: nil)
        let managedURL = fixture.root.appendingPathComponent(relativeBookPath)
        try FileManager.default.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a ready, fingerprinted managed book".utf8).write(to: managedURL)
        try await fixture.store.upsert(book)
        try await authorizeManagedSource(book, in: fixture, at: managedURL)

        let extractor = ExtractorSpy(payload: try makePNG())
        fixture.storage = BookFileStorage(rootURL: fixture.root, bookStore: fixture.store,
                                          coverExtractors: ["epub": extractor])
        let vm = makeViewModel(fixture)
        await vm.refresh()
        await vm.waitForHydration()

        try assertPublishedImage(vm.coverURLs[book.id])
        #expect(await extractor.callCount() == 1)
        #expect(try await fixture.registry.managedSource(for: book) != nil)
    }

    @Test("factory does not publish a tombstoned book's saved image")
    func factoryRejectsTombstonedCover() async throws {
        let id = UUID()
        let fixture = try makeFixture("tombstone", tombstonedBookID: id)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let relativeCoverPath = "Books/\(id.uuidString)/cover.png"
        let book = Book(id: id, userId: fixture.owner, title: "Deleted cover", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: relativeCoverPath)
        let coverURL = fixture.root.appendingPathComponent(relativeCoverPath)
        try FileManager.default.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePNG().write(to: coverURL)
        try await fixture.store.upsert(book)

        let vm = makeViewModel(fixture)
        await vm.refresh()
        await vm.waitForHydration()

        #expect(vm.coverURLs[book.id] == nil)
    }

    @Test("factory rejects artwork resolved across an account generation change")
    func factoryRejectsLateArtworkAfterGenerationChange() async throws {
        var fixture = try makeFixture("generation-race")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let relativeCoverPath = "Books/\(id.uuidString)/cover.png"
        let book = Book(id: id, userId: fixture.owner, title: "Late artwork", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: relativeCoverPath)
        let coverURL = fixture.root.appendingPathComponent(relativeCoverPath)
        try FileManager.default.createDirectory(at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePNG().write(to: coverURL)
        try await fixture.store.upsert(book)

        let gate = BookLookupGate()
        let extractor = ExtractorSpy()
        fixture.storage = BookFileStorage(
            rootURL: fixture.root,
            bookStore: GatedBookStore(base: fixture.store, gate: gate),
            coverExtractors: ["epub": extractor]
        )
        let vm = makeViewModel(fixture)
        await vm.refresh()
        let didEnterLookup = await gate.waitUntilEntered()
        if !didEnterLookup { await gate.open() }
        #expect(didEnterLookup)
        fixture.generationState.set(fixture.generation + 1)
        await gate.open()
        await vm.waitForHydration()

        #expect(vm.coverURLs[book.id] == nil)
        #expect(await extractor.callCount() == 0)
    }

    @Test("otherwise ready managed source cannot turn a final canonical mismatch into a miss")
    func readyManagedSourceRejectsFinalCanonicalMismatch() async throws {
        var fixture = try makeFixture("ready-canonical-race")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = UUID()
        let relativeBookPath = "Books/\(id.uuidString)/\(id.uuidString).epub"
        let relativeCoverPath = "Books/\(id.uuidString)/cover.png"
        let book = Book(id: id, userId: fixture.owner, title: "Ready source", formatType: .epub,
                        fileURL: relativeBookPath, coverPath: relativeCoverPath)
        let managedURL = fixture.root.appendingPathComponent(relativeBookPath)
        let coverURL = fixture.root.appendingPathComponent(relativeCoverPath)
        try FileManager.default.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed bytes for a fully fingerprinted source".utf8).write(to: managedURL)
        try makePNG().write(to: coverURL)
        try await fixture.store.upsert(book)

        try await authorizeManagedSource(book, in: fixture, at: managedURL)

        let gate = BookLookupGate()
        let extractor = ExtractorSpy()
        fixture.storage = BookFileStorage(
            rootURL: fixture.root,
            bookStore: GatedBookStore(base: fixture.store, gate: gate, pauseAtLookup: 2),
            coverExtractors: ["epub": extractor]
        )
        let vm = makeViewModel(fixture)
        await vm.refresh()
        let didEnterLookup = await gate.waitUntilEntered()
        if !didEnterLookup { await gate.open() }
        #expect(didEnterLookup)
        var changed = book
        changed.title = "Canonical changed during image lookup"
        try await fixture.store.upsert(changed)
        await gate.open()
        await vm.waitForHydration()

        #expect(vm.coverURLs[book.id] == nil)
        #expect(await extractor.callCount() == 0)
        #expect(try FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Caches/book-covers/\(id.uuidString).heic").path) == false)
    }
}

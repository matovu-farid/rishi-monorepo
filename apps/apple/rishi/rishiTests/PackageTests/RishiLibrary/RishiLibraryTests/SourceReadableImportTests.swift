@testable import rishi
import CryptoKit
import Foundation
import Testing

@Suite("Source-readable import registration")
struct SourceReadableImportTests {
    private actor CopyGate {
        private var isOpen = false
        private var didStart = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func startAndWait() async {
            didStart = true
            let started = startWaiters
            startWaiters.removeAll()
            started.forEach { $0.resume() }
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor SourceReadableStorage: BookImportingStorage {
        let book: Book
        let gate: CopyGate
        private(set) var registered: (URL, UserID, UInt64)?
        private(set) var returnedWhileCopyHeld = false
        private var selectedBytes: Data?
        private var selectedHash: String?

        init(book: Book, gate: CopyGate) {
            self.book = book
            self.gate = gate
        }

        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?) async throws -> Book {
            book
        }

        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?, accountGeneration: UInt64) async throws -> Book {
            book
        }

        func registerSourceReadable(from sourceURL: URL, ownerId: UserID, accountGeneration: UInt64) async throws -> SourceReadableBookRegistration {
            let bytes = try Data(contentsOf: sourceURL)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            selectedBytes = bytes
            selectedHash = hash
            registered = (sourceURL, ownerId, accountGeneration)
            Task { await gate.startAndWait() }
            await gate.waitUntilStarted()
            returnedWhileCopyHeld = true
            return SourceReadableBookRegistration(book: book, selectedContentHash: hash, state: .copying)
        }

        func readSelectedSource() -> Data? { selectedBytes }
        func selectedContentHash() -> String? { selectedHash }
    }

    @Test("returns the registered book while managed copying is still held")
    func returnsBeforeCopyCompletes() async throws {
        let ownerID = UUID()
        let generation: UInt64 = 18
        let book = Book(userId: ownerID, title: "Large PDF", formatType: .pdf, fileURL: "Books/large.pdf")
        let gate = CopyGate()
        let storage = SourceReadableStorage(book: book, gate: gate)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-readable-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        let selectedBytes = Data("selected PDF bytes".utf8)
        try selectedBytes.write(to: source)
        let coordinator = ImportCoordinator(storage: storage, currentUserId: { ownerID })

        let registration = try await coordinator.registerSourceReadable(
            from: source,
            ownerId: ownerID,
            accountGeneration: generation
        )

        #expect(registration.book.id == book.id)
        #expect(registration.book.title == "Large PDF")
        #expect(registration.state == .copying)
        #expect(registration.selectedContentHash == SHA256.hash(data: selectedBytes).map { String(format: "%02x", $0) }.joined())
        #expect(await storage.returnedWhileCopyHeld)
        #expect(await storage.readSelectedSource() == selectedBytes)
        #expect(try Data(contentsOf: source) == selectedBytes)
        #expect(await storage.selectedContentHash() == registration.selectedContentHash)
        let observed = await storage.registered
        #expect(observed?.0 == source)
        #expect(observed?.1 == ownerID)
        #expect(observed?.2 == generation)
        await gate.open()
    }

    @Test("legacy storage implementations retain managed-on-return behavior")
    func legacyStorageDefaultsToManagedRegistration() async throws {
        let ownerID = UUID()
        let book = Book(userId: ownerID, title: "Already managed", formatType: .epub, fileURL: "Books/book.epub")
        let storage = LegacyStorage(book: book)
        let coordinator = ImportCoordinator(storage: storage, currentUserId: { ownerID })

        let registration = try await coordinator.registerSourceReadable(
            from: URL(fileURLWithPath: "/tmp/book.epub"),
            ownerId: ownerID,
            accountGeneration: 4
        )

        #expect(registration.book.id == book.id)
        #expect(registration.state == .managed)
    }

    private struct LegacyStorage: BookImportingStorage {
        let book: Book
        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?) async throws -> Book { book }
    }
}

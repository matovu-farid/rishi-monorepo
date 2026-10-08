@testable import rishi
import Foundation
import Testing

private let testBookDigest = String(repeating: "a", count: 64)

@Suite(.serialized)
struct BookFingerprintServiceTests {
    @Test("different-sized managed books are skipped without hashing")
    func skipsDifferentSizes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("small".utf8))
        let store = InMemoryBookStore(initial: [book])
        let persistence = FingerprintPersistence()
        let hashes = HashCounter()
        let service = BookFingerprintService(rootURL: root, bookStore: store, persistence: persistence, hashFile: { _ in hashes.increment(); return testBookDigest })

        let result = try await service.matchingBook(ownerID: owner, byteCount: 20, sha256: testBookDigest)

        #expect(result == nil)
        #expect(hashes.value == 0)
    }

    @Test("a fresh verified fingerprint matches without hashing the managed file")
    func reusesFreshFingerprint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("same".utf8))
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: root.appendingPathComponent(book.fileURL), materializationRevision: UUID()))
        let persistence = FingerprintPersistence(fingerprint: BookFileFingerprint(bookID: book.id, ownerID: owner, sha256: testBookDigest, version: version))
        let hashes = HashCounter()
        let service = BookFingerprintService(rootURL: root, bookStore: InMemoryBookStore(initial: [book]), persistence: persistence, currentGeneration: { 1 }, hashFile: { _ in hashes.increment(); return testBookDigest })

        let result = try await service.matchingBook(ownerID: owner, byteCount: 4, sha256: testBookDigest)

        #expect(result?.id == book.id)
        #expect(hashes.value == 0)
    }

    @Test("a same-sized legacy candidate is hashed once and its digest is cached")
    func hashesAndCachesLegacyCandidate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("same".utf8))
        let persistence = FingerprintPersistence()
        let hashes = HashCounter()
        let service = BookFingerprintService(rootURL: root, bookStore: InMemoryBookStore(initial: [book]), persistence: persistence, currentGeneration: { 1 }, hashFile: { _ in hashes.increment(); return testBookDigest })

        let result = try await service.matchingBook(ownerID: owner, byteCount: 4, sha256: testBookDigest)

        #expect(result?.id == book.id)
        #expect(hashes.value == 1)
        #expect((try await persistence.fingerprint(bookID: book.id, ownerID: owner))?.sha256 == testBookDigest)
    }

    @Test("a changed managed version invalidates its cached digest")
    func changedVersionRehashesInsteadOfReusingFingerprint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("same".utf8))
        let url = root.appendingPathComponent(book.fileURL)
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: url, materializationRevision: UUID()))
        let persistence = FingerprintPersistence(fingerprint: BookFileFingerprint(bookID: book.id, ownerID: owner, sha256: testBookDigest, version: version))
        try Data("else".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let hashes = HashCounter()
        let changedDigest = String(repeating: "b", count: 64)
        let service = BookFingerprintService(rootURL: root, bookStore: InMemoryBookStore(initial: [book]), persistence: persistence, hashFile: { _ in hashes.increment(); return changedDigest })

        let result = try await service.matchingBook(ownerID: owner, byteCount: 4, sha256: testBookDigest)

        #expect(result == nil)
        #expect(hashes.value == 1)
    }

    @Test("a probe rejects a source changed before coordinated copy")
    func rejectsChangedSourceBeforeCopy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        let staging = root.appendingPathComponent("staging.partial")
        try Data("original".utf8).write(to: source)
        let probe = CoordinatedSourceProbe()
        let selected = try await probe.probe(source)
        try Data("modified".utf8).write(to: source, options: .atomic)

        await #expect(throws: CoordinatedSourceProbe.ProbeError.self) {
            try await probe.copyVerifiedSource(source, to: staging, expected: selected)
        }

        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("verified managed bytes remain usable when fingerprint cache CAS declines")
    func distinguishesVerificationFromCachePersistence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("verified".utf8))
        let service = BookFingerprintService(
            rootURL: root,
            bookStore: InMemoryBookStore(initial: [book]),
            persistence: FingerprintPersistence(allowCache: false)
        )

        let result = await service.verifyAndCacheManagedFile(for: book)

        #expect(result?.fingerprint.version.byteCount == 8)
        #expect(result?.fingerprintPersisted == false)
    }

    @Test("ready materialization rehash repairs a missing or corrupt fingerprint with its promotion revision")
    func repairsReadyMaterializationFingerprint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let bytes = Data("same".utf8)
        let book = try makeBook(root: root, owner: owner, bytes: bytes)
        let url = root.appendingPathComponent(book.fileURL)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: url, materializationRevision: revision))
        let pending = readyJob(book: book, digest: testBookDigest, byteCount: 4, version: version)
        let corrupt = BookFileFingerprint(bookID: book.id, ownerID: owner, sha256: String(repeating: "b", count: 64), version: version)
        let persistence = FingerprintPersistence(fingerprint: corrupt, pending: pending)
        let hashes = HashCounter()
        let service = BookFingerprintService(
            rootURL: root,
            bookStore: InMemoryBookStore(initial: [book]),
            persistence: persistence,
            currentGeneration: { 1 },
            hashFile: { _ in hashes.increment(); return testBookDigest }
        )

        let repaired = await service.verifyAndCacheManagedFile(for: book, expectedSHA256: testBookDigest, expectedByteCount: 4)

        #expect(repaired?.fingerprintPersisted == true)
        #expect(repaired?.fingerprint.version == version)
        #expect(repaired?.fingerprint.version.materializationRevision == revision)
        #expect(hashes.value == 1)
        #expect((try await persistence.fingerprint(bookID: book.id, ownerID: owner))?.sha256 == testBookDigest)
    }

    @Test("legacy Book without a pending job still receives a fresh fingerprint")
    func cachesLegacyBookWithoutPendingJob() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("legacy".utf8))
        let persistence = FingerprintPersistence()
        let service = BookFingerprintService(
            rootURL: root,
            bookStore: InMemoryBookStore(initial: [book]),
            persistence: persistence,
            currentGeneration: { 1 },
            hashFile: { _ in testBookDigest }
        )

        let result = await service.verifyAndCacheManagedFile(for: book)

        #expect(result?.fingerprintPersisted == true)
        #expect(result?.fingerprint.sha256 == testBookDigest)
        #expect((try await persistence.fingerprint(bookID: book.id, ownerID: owner)) == result?.fingerprint)
    }

    @Test("unchanged legacy fingerprint reseeding preserves the content revision")
    func unchangedLegacyReseedPreservesRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = try makeBook(root: root, owner: owner, bytes: Data("legacy".utf8))
        let originalRevision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(
            at: root.appendingPathComponent(book.fileURL),
            materializationRevision: originalRevision
        ))
        let cached = BookFileFingerprint(
            bookID: book.id,
            ownerID: owner,
            sha256: testBookDigest,
            version: version
        )
        let persistence = FingerprintPersistence(fingerprint: cached)
        let service = BookFingerprintService(
            rootURL: root,
            bookStore: InMemoryBookStore(initial: [book]),
            persistence: persistence,
            hashFile: { _ in testBookDigest }
        )

        let refreshed = await service.verifyAndCacheManagedFile(for: book)

        #expect(refreshed?.fingerprint.version == version)
        #expect((try await persistence.fingerprint(bookID: book.id, ownerID: owner)?.version.materializationRevision) == originalRevision)
    }

    private func makeRoot() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent("BookFingerprint-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBook(root: URL, owner: UserID, bytes: Data) throws -> Book {
        let id = UUID()
        let relativePath = "Books/\(id.uuidString)/book.pdf"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return Book(id: id, userId: owner, title: "Book", formatType: .pdf, fileURL: relativePath)
    }

    private func readyJob(book: Book, digest: String, byteCount: Int64, version: ManagedFileVersion) -> PendingBookMaterialization {
        PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: 1, bookID: book.id, attemptID: UUID()),
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: "staging/source.pdf",
            sourceVersion: ManagedFileVersion(byteCount: byteCount, modificationDate: version.modificationDate, fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: digest,
            expectedByteCount: byteCount,
            stagingRelativePath: "staging/book.part",
            destinationRelativePath: book.fileURL,
            phase: .ready,
            destinationFileIdentifier: version.fileIdentifier,
            promotionRevision: version.materializationRevision
        )
    }
}

private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private actor FingerprintPersistence: BookFingerprintPersistence {
    private var stored: [BookID: BookFileFingerprint] = [:]
    private let allowCache: Bool
    private let pending: PendingBookMaterialization?
    init(fingerprint: BookFileFingerprint? = nil, pending: PendingBookMaterialization? = nil, allowCache: Bool = true) {
        self.allowCache = allowCache
        self.pending = pending
        if let fingerprint { stored[fingerprint.bookID] = fingerprint }
    }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        guard let value = stored[bookID], value.ownerID == ownerID else { return nil }
        return value
    }
    private func storeValidatedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool {
        guard allowCache, fingerprint.version == expectedVersion else { return false }
        if let pending {
            guard pending.phase == .ready,
                  pending.token.bookID == fingerprint.bookID,
                  pending.token.ownerID == fingerprint.ownerID,
                  pending.expectedSHA256.caseInsensitiveCompare(fingerprint.sha256) == .orderedSame,
                  pending.expectedByteCount == fingerprint.version.byteCount,
                  pending.destinationRelativePath == expectedRelativePath,
                  pending.destinationFileIdentifier == fingerprint.version.fileIdentifier,
                  pending.promotionRevision == fingerprint.version.materializationRevision else { return false }
        }
        stored[fingerprint.bookID] = fingerprint
        return true
    }
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool {
        guard expectedGeneration == 1 else { return false }
        return try await storeValidatedFingerprint(fingerprint, expectedRelativePath: expectedRelativePath, expectedVersion: expectedVersion)
    }
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        guard pending?.token.bookID == bookID, pending?.token.ownerID == ownerID else { return nil }
        return pending
    }
}

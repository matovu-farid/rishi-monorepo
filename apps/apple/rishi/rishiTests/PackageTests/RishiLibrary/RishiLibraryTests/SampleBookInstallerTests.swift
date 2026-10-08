@testable import rishi
import CryptoKit
import Foundation
import Testing

@Suite("SampleBookInstaller")
struct SampleBookInstallerTests {
    @Test("explicit selection installs a sample for each account even when the legacy flag is set")
    func explicitSelectionIsAccountScoped() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let defaults = makeDefaults()
        defaults.set(true, forKey: SampleBookInstaller.defaultsKey)
        let installer = SampleBookInstaller(storage: storage, defaults: defaults)
        let firstOwner = UUID()
        let secondOwner = UUID()

        let first = try await installer.installOrFind(
            ownerId: firstOwner, accountGeneration: 1, isCurrentAccount: { true }
        )
        let second = try await installer.installOrFind(
            ownerId: secondOwner, accountGeneration: 1, isCurrentAccount: { true }
        )

        #expect(first.userId == firstOwner)
        #expect(second.userId == secondOwner)
        #expect(first.id != second.id)
        #expect(try await store.books(for: firstOwner).map(\.id) == [first.id])
        #expect(try await store.books(for: secondOwner).map(\.id) == [second.id])
        #expect(defaults.bool(forKey: SampleBookInstaller.defaultsKey))
    }

    @Test("repeated explicit selection returns the same readable owned book")
    func repeatedSelectionFindsExistingSample() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let defaults = makeDefaults()
        let installer = SampleBookInstaller(storage: storage, defaults: defaults)
        let owner = UUID()

        let first = try await installer.installOrFind(
            ownerId: owner, accountGeneration: 4, isCurrentAccount: { true }
        )
        let next = try await installer.installOrFind(
            ownerId: owner, accountGeneration: 4, isCurrentAccount: { true }
        )

        #expect(next.id == first.id)
        #expect(next.userId == owner)
        #expect(next.formatType == .epub)
        #expect(try await store.books(for: owner).count == 1)
        #expect(!defaults.bool(forKey: SampleBookInstaller.defaultsKey))
    }

    @Test("explicit selection reinstalls a deleted sample")
    func deletedSampleIsReinstalledOnSelection() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let installer = SampleBookInstaller(storage: storage, defaults: makeDefaults())
        let owner = UUID()
        let first = try await installer.installOrFind(
            ownerId: owner, accountGeneration: 2, isCurrentAccount: { true }
        )
        try await storage.delete(first)

        let reinstalled = try await installer.installOrFind(
            ownerId: owner, accountGeneration: 2, isCurrentAccount: { true }
        )

        #expect(reinstalled.userId == owner)
        #expect(reinstalled.formatType == .epub)
        #expect(try await store.books(for: owner).count == 1)
    }

    @Test("missing managed bytes repair the exact sample row on explicit retry")
    func missingManagedSampleBytesAreRepairedAtSameBookID() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let generation: UInt64 = 7
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: owner, generation: generation)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(
            sourceRegistry: registry,
            currentAccountGeneration: { generation }
        )
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: books,
            currentGeneration: { generation }
        )
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            metadataExtractors: [:],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )
        let installer = SampleBookInstaller(storage: storage, defaults: makeDefaults())

        let installed = try await installer.installOrFind(
            ownerId: owner, accountGeneration: generation, isCurrentAccount: { true }
        )
        _ = try await coordinator.awaitManagedSource(for: installed)
        let managedURL = root.appendingPathComponent(installed.fileURL)
        let savedFingerprint = try #require(
            await persistence.fingerprint(bookID: installed.id, ownerID: owner)
        )
        let savedReadingPermit = try #require(
            try await persistence.readingPermit(bookID: installed.id, ownerID: owner, generation: generation)
        )
        #expect(installed.formatType == .epub)
        #expect(FileManager.default.fileExists(atPath: managedURL.path))

        try FileManager.default.removeItem(at: managedURL)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))

        let priorJob = try #require(await persistence.pendingMaterialization(bookID: installed.id, ownerID: owner))
        let activeOldAttempt = try #require(lifecycle.admitBookMaterialization(priorJob.token))
        let bundledSample = try #require(AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        await #expect(throws: Error.self) {
            _ = try await storage.repairMissingSample(
                for: installed, from: bundledSample, ownerID: owner, accountGeneration: generation
            )
        }
        #expect(try await persistence.pendingMaterialization(bookID: installed.id, ownerID: owner)?.token == priorJob.token)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
        activeOldAttempt.release()

        let retried = try await installer.installOrFind(
            ownerId: owner, accountGeneration: generation, isCurrentAccount: { true }
        )

        #expect(retried.id == installed.id)
        #expect(try await books.books(for: owner).map(\.id) == [installed.id])
        let restoredBytes = try Data(contentsOf: managedURL)
        let restoredDigest = SHA256.hash(data: restoredBytes).map { String(format: "%02x", $0) }.joined()
        #expect(restoredDigest == savedFingerprint.sha256)
        let lease = try await registry.acquireReadableSource(for: retried)
        #expect(lease.url.standardizedFileURL == managedURL.standardizedFileURL)
        #expect(try await persistence.fingerprint(bookID: retried.id, ownerID: owner)?.sha256 == savedFingerprint.sha256)
        #expect(try await persistence.readingPermit(bookID: retried.id, ownerID: owner, generation: generation) == savedReadingPermit)

        try FileManager.default.removeItem(at: managedURL)
        let repairedAgain = try await installer.installOrFind(
            ownerId: owner, accountGeneration: generation, isCurrentAccount: { true }
        )
        #expect(repairedAgain.id == installed.id)
        #expect(try await books.books(for: owner).map(\.id) == [installed.id])
        let secondBytes = try Data(contentsOf: managedURL)
        let secondDigest = SHA256.hash(data: secondBytes).map { String(format: "%02x", $0) }.joined()
        #expect(secondDigest == savedFingerprint.sha256)
        #expect(try await persistence.fingerprint(bookID: repairedAgain.id, ownerID: owner)?.sha256 == savedFingerprint.sha256)
        #expect(try await persistence.readingPermit(bookID: repairedAgain.id, ownerID: owner, generation: generation) == savedReadingPermit)
        let secondLease = try await registry.acquireReadableSource(for: repairedAgain)
        #expect(secondLease.url.standardizedFileURL == managedURL.standardizedFileURL)
    }

    @Test("missing bundled resource throws a typed installer error")
    func missingResourceThrowsTypedError() async throws {
        let root = makeRoot()
        let storage = BookFileStorage(rootURL: root, bookStore: InMemoryBookStore(), coverExtractors: [:])
        let installer = SampleBookInstaller(
            storage: storage,
            defaults: makeDefaults(),
            bundle: Bundle(for: NSObject.self)
        )

        do {
            _ = try await installer.installOrFind(
                ownerId: UUID(), accountGeneration: 1, isCurrentAccount: { true }
            )
            Issue.record("Expected missing sample resource to be reported")
        } catch let error as SampleBookInstallerError {
            guard case .missingResource = error else {
                Issue.record("Expected missingResource, got \(error)")
                return
            }
        }
    }

    @Test("storage failures are exposed as the import failure case")
    func importFailureThrowsTypedError() async throws {
        let storage = BookFileStorage(
            rootURL: makeRoot(),
            bookStore: FailingBookStore(),
            coverExtractors: [:]
        )
        let installer = SampleBookInstaller(storage: storage, defaults: makeDefaults())

        do {
            _ = try await installer.installOrFind(
                ownerId: UUID(), accountGeneration: 1, isCurrentAccount: { true }
            )
            Issue.record("Expected storage import failure to be reported")
        } catch let error as SampleBookInstallerError {
            guard case .importFailed = error else {
                Issue.record("Expected importFailed, got \(error)")
                return
            }
        }
    }

    @Test("an account that changed while installation was suspended cannot trigger the import callback")
    func staleAccountSuppressesCallback() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let callback = CallbackRecorder()
        let installer = SampleBookInstaller(
            storage: storage,
            defaults: makeDefaults(),
            onBookImported: { id in await callback.append(id) }
        )
        let owner = UUID()
        let current = CurrentAccountFlag()

        do {
            _ = try await installer.installOrFind(
                ownerId: owner,
                accountGeneration: 7,
                isCurrentAccount: { await current.check() }
            )
            Issue.record("Expected changed account to invalidate the selection")
        } catch let error as SampleBookInstallerError {
            guard case .accountChanged = error else {
                Issue.record("Expected accountChanged, got \(error)")
                return
            }
        }

        #expect(await callback.ids.isEmpty)
    }

    @Test("cancelled selection suppresses the import callback")
    func cancelledSelectionSuppressesCallback() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let callback = CallbackRecorder()
        let installer = SampleBookInstaller(
            storage: storage,
            defaults: makeDefaults(),
            onBookImported: { id in await callback.append(id) }
        )
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try await installer.installOrFind(
                ownerId: UUID(), accountGeneration: 1, isCurrentAccount: { true }
            )
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancelled selection to throw")
        } catch is CancellationError {
            // Expected cancellation remains distinguishable from import failure.
        }

        #expect(await callback.ids.isEmpty)
    }

    @Test("cancellation while account validation is suspended before storage skips the import")
    func cancellationDuringPreStorageAccountCheckSkipsStorage() async throws {
        let store = CountingBookStore()
        let storage = BookFileStorage(rootURL: makeRoot(), bookStore: store, coverExtractors: [:])
        let callback = CallbackRecorder()
        let installer = SampleBookInstaller(
            storage: storage,
            defaults: makeDefaults(),
            onBookImported: { id in await callback.append(id) }
        )
        let validity = SuspendedAccountValidity(waitAtCheck: 1)
        let task = Task.detached {
            try await installer.installOrFind(
                ownerId: UUID(), accountGeneration: 1, isCurrentAccount: { await validity.check() }
            )
        }

        await validity.waitUntilSuspended()
        task.cancel()
        await validity.resume()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop the pre-storage selection")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await store.operationCount == 0)
        #expect(await callback.ids.isEmpty)
    }

    @Test("cancellation during the final account check suppresses the import callback")
    func cancellationDuringPreCallbackAccountCheckSuppressesCallback() async throws {
        let store = CountingBookStore()
        let storage = BookFileStorage(rootURL: makeRoot(), bookStore: store, coverExtractors: [:])
        let callback = CallbackRecorder()
        let installer = SampleBookInstaller(
            storage: storage,
            defaults: makeDefaults(),
            onBookImported: { id in await callback.append(id) }
        )
        let validity = SuspendedAccountValidity(waitAtCheck: 3)
        let task = Task.detached {
            try await installer.installOrFind(
                ownerId: UUID(), accountGeneration: 1, isCurrentAccount: { await validity.check() }
            )
        }

        await validity.waitUntilSuspended()
        task.cancel()
        await validity.resume()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop before the import callback")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await store.operationCount > 0)
        #expect(await callback.ids.isEmpty)
    }

    @Test("mismatched persisted provenance refuses the deterministic same-metadata row without duplication")
    func unsafeSampleProvenanceDoesNotCreateDuplicate() async throws {
        let owner = UUID()
        let resource = try #require(AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let bootstrapRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: bootstrapRoot) }
        let bootstrapStore = InMemoryBookStore()
        let bootstrapStorage = BookFileStorage(
            rootURL: bootstrapRoot,
            bookStore: bootstrapStore,
            coverExtractors: [:],
            metadataExtractors: ["epub": EpubMetadataExtractor()]
        )
        let existing = try await bootstrapStorage.importBook(from: resource, ownerId: owner)

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation: UInt64 = 9
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        try await books.upsert(existing)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: owner, generation: generation)
        let managedURL = root.appendingPathComponent(existing.fileURL)
        try FileManager.default.createDirectory(
            at: managedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: bootstrapRoot.appendingPathComponent(existing.fileURL),
            to: managedURL
        )
        let revision = UUID()
        let observedVersion = try #require(
            try FileManagedFileVersionInspector().managedFileVersion(
                at: managedURL,
                materializationRevision: revision
            )
        )
        let mismatchedFingerprint = BookFileFingerprint(
            bookID: existing.id,
            ownerID: owner,
            sha256: String(repeating: "0", count: 64),
            version: observedVersion
        )
        #expect(try await persistence.cacheManagedFingerprint(
            mismatchedFingerprint,
            expectedGeneration: generation,
            expectedRelativePath: existing.fileURL,
            expectedVersion: observedVersion
        ))
        try FileManager.default.removeItem(at: managedURL)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: books,
            currentGeneration: { generation }
        )
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            metadataExtractors: ["epub": EpubMetadataExtractor()],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )

        do {
            _ = try await storage.installOrRepairSample(
                from: resource, ownerID: owner, accountGeneration: generation
            )
            Issue.record("Expected missing provenance to refuse sample repair")
        } catch let error as BookFileStorage.StorageError {
            guard case .sampleProvenanceUnavailable = error else {
                Issue.record("Expected sampleProvenanceUnavailable, got \(error)")
                return
            }
        }

        #expect(try await books.books(for: owner).map(\.id) == [existing.id])
        #expect(try await books.book(existing.id) == existing)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
    }

    @Test("rotated-ID same-metadata row with unreadable bytes refuses fallback import")
    func rotatedIDSameMetadataRowDoesNotCreateNewSample() async throws {
        let owner = UUID()
        let resource = try #require(AppResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let bootstrapRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: bootstrapRoot) }
        let bootstrapStorage = BookFileStorage(
            rootURL: bootstrapRoot,
            bookStore: InMemoryBookStore(),
            coverExtractors: [:]
        )
        let metadataBook = try await bootstrapStorage.importBook(from: resource, ownerId: owner)
        let rotatedID = UUID()
        let rotatedBook = Book(
            id: rotatedID,
            userId: owner,
            title: metadataBook.title,
            author: metadataBook.author,
            formatType: .epub,
            addedAt: metadataBook.addedAt,
            openedAt: metadataBook.openedAt,
            fileURL: "Books/\(rotatedID.uuidString)/alice.epub",
            coverPath: metadataBook.coverPath,
            positionId: metadataBook.positionId,
            conversationId: metadataBook.conversationId,
            chapterIndexContentVersion: metadataBook.chapterIndexContentVersion
        )

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let managedURL = root.appendingPathComponent(rotatedBook.fileURL)
        try FileManager.default.createDirectory(
            at: managedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00, 0xff, 0x01]).write(to: managedURL)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        try await books.upsert(rotatedBook)
        let generation: UInt64 = 9
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: owner, generation: generation)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: books,
            currentGeneration: { generation }
        )
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            metadataExtractors: [:],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )
        let installer = SampleBookInstaller(storage: storage, defaults: makeDefaults())
        let filesBeforeRetry = try FileManager.default.contentsOfDirectory(
            at: managedURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)

        do {
            _ = try await installer.installOrFind(
                ownerId: owner, accountGeneration: generation, isCurrentAccount: { true }
            )
            Issue.record("Expected the same-metadata row without exact provenance to block fallback import")
        } catch let error as SampleBookInstallerError {
            guard case .provenanceUnavailable = error else {
                Issue.record("Expected provenanceUnavailable, got \(error)")
                return
            }
        }

        #expect(try await books.books(for: owner).map(\.id) == [rotatedID])
        #expect(try await books.book(rotatedID) == rotatedBook)
        let filesAfterRetry = try FileManager.default.contentsOfDirectory(
            at: managedURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(filesAfterRetry == filesBeforeRetry)
        #expect(try Data(contentsOf: managedURL) == Data([0x00, 0xff, 0x01]))
    }

    @Test("installIfNeeded preserves the legacy device-wide fixture flag")
    func legacyInstallerRemainsOneShot() async throws {
        let root = makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let defaults = makeDefaults()
        let installer = SampleBookInstaller(storage: storage, defaults: defaults)
        let owner = UUID()

        let first = await installer.installIfNeeded(ownerId: owner)
        let second = await installer.installIfNeeded(ownerId: owner)

        #expect(first != nil)
        #expect(second == nil)
        #expect(defaults.bool(forKey: SampleBookInstaller.defaultsKey))
    }

    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SampleBookInstaller-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SampleBookInstallerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor CallbackRecorder {
    private(set) var ids: [BookID] = []
    func append(_ id: BookID) { ids.append(id) }
}

private actor CurrentAccountFlag {
    private var checks = 0

    func check() -> Bool {
        checks += 1
        return checks == 1
    }
}

private actor FailingBookStore: BookStore {
    private enum Failure: Error { case storageUnavailable }

    func books(for userId: UserID) async throws -> [Book] { throw Failure.storageUnavailable }
    func book(_ id: BookID) async throws -> Book? { throw Failure.storageUnavailable }
    func upsert(_ book: Book) async throws { throw Failure.storageUnavailable }
    func delete(_ id: BookID) async throws { throw Failure.storageUnavailable }
}

private actor CountingBookStore: BookStore {
    private var booksByID: [BookID: Book] = [:]
    private(set) var operationCount = 0
    func books(for userId: UserID) async throws -> [Book] {
        operationCount += 1
        return booksByID.values.filter { $0.userId == userId }
    }
    func book(_ id: BookID) async throws -> Book? {
        operationCount += 1
        return booksByID[id]
    }
    func upsert(_ book: Book) async throws {
        operationCount += 1
        booksByID[book.id] = book
    }
    func delete(_ id: BookID) async throws {
        operationCount += 1
        booksByID.removeValue(forKey: id)
    }
}

private actor SuspendedAccountValidity {
    private let waitAtCheck: Int
    private var checks = 0
    private var suspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    init(waitAtCheck: Int) { self.waitAtCheck = waitAtCheck }
    func check() async -> Bool {
        checks += 1
        guard checks == waitAtCheck else { return true }
        suspended = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { resumeWaiters.append($0) }
        return true
    }
    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func resume() {
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }
}

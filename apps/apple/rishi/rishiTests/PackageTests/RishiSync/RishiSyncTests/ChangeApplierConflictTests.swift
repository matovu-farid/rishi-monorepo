@testable import rishi
import Testing
import Foundation




/// SYNC-04 — ChangeApplier conflict resolution policy:
///   - Positions: last-write-wins by `updatedAt`. Server's updatedAt is
///     authoritative; ties favor local (server-newer overwrites only when
///     strictly newer).
///   - Highlights: merge by ID. Same ID + diverged content → latest
///     `createdAt` wins. Different IDs are kept (no conflict).
///   - Book metadata: deleted=true cascades through bookStore.delete and
///     retains a clean metadata tombstone. Live rows upsert into BookStore.
///   - Conversation / Message kinds are accepted but skipped (Phase 9 will
///     wire) — metadata.markClean still called so we don't echo the cursor.
@Suite("ChangeApplier — SYNC-04 conflict resolution", .serialized)
struct ChangeApplierConflictTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []
        var forgetCalls: [(UUID, SyncEntityKind)] = []
        var tombstoneAcknowledgements: [(UUID, SyncEntityKind)] = []
        var remoteSeenCalls: [(UUID, SyncEntityKind, Date)] = []
        var dirtyRows: [String: Date] = [:]

        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
        }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            forgetCalls.append((entityId, kind))
        }
        func markCleanIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
            return true
        }
        func acknowledgeTombstoneIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            tombstoneAcknowledgements.append((entityId, kind))
            return true
        }
        func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? {
            dirtyRows["\(entityId.uuidString):\(kind.rawValue)"]
        }
        func seedDirty(_ entityId: UUID, kind: SyncEntityKind) {
            dirtyRows["\(entityId.uuidString):\(kind.rawValue)"] = Date(timeIntervalSince1970: 1_700_000_000)
        }
        func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {
            remoteSeenCalls.append((entityId, kind, updatedAt))
        }
        func cleaned() -> [(UUID, SyncEntityKind, Date, String?)] { cleanCalls }
        func forgotten() -> [(UUID, SyncEntityKind)] { forgetCalls }
        func acknowledgedTombstones() -> [(UUID, SyncEntityKind)] { tombstoneAcknowledgements }
        func remoteSeen() -> [(UUID, SyncEntityKind, Date)] { remoteSeenCalls }
    }

    private actor StubBookStore: BookStore {
        var rows: [BookID: Book] = [:]
        var rejectNextConditionalDelete = false
        func seed(_ book: Book) { rows[book.id] = book }
        func rejectNextDelete() { rejectNextConditionalDelete = true }
        func books(for userId: UserID) async throws -> [Book] { Array(rows.values) }
        func book(_ id: BookID) async throws -> Book? { rows[id] }
        func upsert(_ book: Book) async throws { rows[book.id] = book }
        func delete(_ id: BookID) async throws { rows[id] = nil }
        func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool {
            if rejectNextConditionalDelete {
                rejectNextConditionalDelete = false
                return false
            }
            guard rows[id] == expected else { return false }
            rows[id] = nil
            return true
        }
        func count() -> Int { rows.count }
    }

    private actor StubPositionStore: PositionStore {
        var rows: [BookID: Position] = [:]
        func seed(_ position: Position) { rows[position.bookId] = position }
        func position(for bookId: BookID) async throws -> Position? { rows[bookId] }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key { rows[key] = nil }
        }
        func snapshot() -> [Position] { Array(rows.values) }
    }

    private actor StubHighlightStore: HighlightStore {
        var rows: [HighlightID: Highlight] = [:]
        func seed(_ highlight: Highlight) { rows[highlight.id] = highlight }
        func highlights(for bookId: BookID) async throws -> [Highlight] {
            rows.values.filter { $0.bookId == bookId }
        }
        func highlight(_ id: HighlightID) async throws -> Highlight? { rows[id] }
        func upsert(_ highlight: Highlight) async throws { rows[highlight.id] = highlight }
        func delete(_ id: HighlightID) async throws { rows[id] = nil }
        func snapshot() -> [Highlight] { Array(rows.values) }
    }

    private actor StubBookmarkStore: BookmarkStore {
        var rows: [BookmarkID: Bookmark] = [:]
        func bookmarks(for bookId: BookID) async throws -> [Bookmark] {
            rows.values.filter { $0.bookId == bookId }
        }
        func bookmark(_ id: BookmarkID) async throws -> Bookmark? { rows[id] }
        func upsert(_ bookmark: Bookmark) async throws { rows[bookmark.id] = bookmark }
        func delete(_ id: BookmarkID) async throws { rows[id] = nil }
    }

    private actor CleanupProbe {
        var ids: [BookID] = []
        func record(_ id: BookID) { ids.append(id) }
        func snapshot() -> [BookID] { ids }
    }

    private actor FingerprintPersistProbe {
        private var answers: [Bool]
        private(set) var calls = 0
        init(answers: [Bool]) { self.answers = answers }
        func persist() -> Bool {
            calls += 1
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private actor InboundAccountPermitProbe {
        private var generation: UInt64 = 1
        private var captured: AccountMutationPermit?
        func permit(ownerID: UserID) -> AccountMutationPermit {
            let value = AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
            captured = value
            return value
        }
        func advanceGeneration() { generation += 1 }
        func currentGeneration() -> UInt64 { generation }
        func capturedPermit() -> AccountMutationPermit? { captured }
    }

    private actor CommitStageProbe {
        private var events: [String] = []
        func record(_ stage: String) { events.append(stage) }
        func snapshot() -> [String] { events }
    }

    private actor RetireProbe {
        private(set) var sawLiveBook = false
        func record(_ value: Bool) { sawLiveBook = value }
    }

    private final class SearchableNotificationProbe: @unchecked Sendable {
        struct Snapshot {
            let delivered: Bool
            let deliveredOnMainThread: Bool
            let applyHadReturnedAtDelivery: Bool
            let applyReturned: Bool
        }

        private let lock = NSLock()
        private var delivered = false
        private var deliveredOnMainThread = false
        private var applyHadReturnedAtDelivery = false
        private var applyReturned = false

        func recordDelivery() {
            lock.lock()
            delivered = true
            deliveredOnMainThread = Thread.isMainThread
            applyHadReturnedAtDelivery = applyReturned
            lock.unlock()
        }

        func markApplyReturned() {
            lock.lock()
            applyReturned = true
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                delivered: delivered,
                deliveredOnMainThread: deliveredOnMainThread,
                applyHadReturnedAtDelivery: applyHadReturnedAtDelivery,
                applyReturned: applyReturned
            )
        }
    }

    private actor BookCleanupSequence {
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    private actor OwnerDeletionAdmission {
        private(set) var ownerID: UserID
        private var activeOperations = 0
        private var switchRequested = false
        private var switchRequestWaiter: CheckedContinuation<Void, Never>?
        private var drainWaiter: CheckedContinuation<Void, Never>?

        init(ownerID: UserID) { self.ownerID = ownerID }

        func withAdmission(ownerID: UserID, operation: @Sendable (UInt64) async throws -> Void) async throws {
            guard self.ownerID == ownerID else { throw Issue269TestFailure.ownerChanged }
            activeOperations += 1
            defer {
                activeOperations -= 1
                if activeOperations == 0 {
                    drainWaiter?.resume()
                    drainWaiter = nil
                }
            }
            try await operation(41)
        }

        func switchOwner(to newOwner: UserID) async {
            switchRequested = true
            switchRequestWaiter?.resume()
            switchRequestWaiter = nil
            if activeOperations > 0 {
                await withCheckedContinuation { drainWaiter = $0 }
            }
            ownerID = newOwner
        }

        func waitUntilSwitchRequested() async {
            guard !switchRequested else { return }
            await withCheckedContinuation { switchRequestWaiter = $0 }
        }
    }

    private actor CleanupGate {
        private var entered = false
        private var released = false

        func enterAndWait() async throws {
            entered = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !entered {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return false }
            }
            return true
        }

        func release() {
            released = true
        }
    }

    private actor PendingDeletionPersistence: BookImportPersistence {
        private var pending: PendingBookMaterialization?
        private var deleteAnswers: [Bool]
        init(pending: PendingBookMaterialization, deleteAnswers: [Bool] = [true]) {
            self.pending = pending
            self.deleteAnswers = deleteAnswers
        }
        func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
            guard let pending else { return nil }
            return pending.token.bookID == bookID && pending.token.ownerID == ownerID ? pending : nil
        }
        func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
            guard let pending else { return nil }
            return pending.token.bookID == bookID && pending.token.ownerID == ownerID ? pending : nil
        }
        func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool {
            guard let pending, pending.token.bookID == bookID,
                  pending.token.ownerID == ownerID, pending.token == expectedToken else { return false }
            let answer = deleteAnswers.isEmpty ? false : deleteAnswers.removeFirst()
            if answer { self.pending = nil }
            return answer
        }
        func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration { fatalError("unused") }
        func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? { fatalError("unused") }
        func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool { false }
        func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool { false }
        func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
        func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
        func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool { false }
        func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool { false }
        func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? { nil }
        func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? { nil }
        func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? { nil }
        func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool { false }
        func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { false }
        func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? {
            guard let pending else { return nil }
            return pending.token.bookID == bookID && pending.token.ownerID == ownerID ? pending : nil
        }
        func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? { nil }
        func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { false }
        func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {}
        func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {}
    }

    // MARK: - Helpers

    private func makeApplier(
        bookStore: any BookStore,
        positionStore: any PositionStore,
        highlightStore: any HighlightStore,
        metadata: any SyncMetadataStore,
        currentUserId: @escaping @Sendable () async -> UserID? = { nil },
        bookMaterialCleanup: (@Sendable (Book) async throws -> Void)? = nil,
        bookMaterialCleanupByID: (@Sendable (BookID) async throws -> Void)? = nil,
        prepareBookMaterialCleanup: (@Sendable (BookID, UserID) async throws -> (@Sendable () async throws -> Void))? = nil,
        withBookDeletionAdmission: (@Sendable (UserID, @Sendable (UInt64) async throws -> Void) async throws -> Void)? = nil,
        restoreBookAfterFailedRetirement: (@Sendable (Book, UInt64?) async -> Bool)? = nil,
        scheduleBookRecovery: (@Sendable (UserID, UInt64) async -> Void)? = nil,
        retireAndDrainBook: (@Sendable (BookID) async throws -> Void)? = nil
    ) -> ChangeApplier {
        ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            bookmarkStore: StubBookmarkStore(),
            metadataStore: metadata,
            currentUserId: currentUserId,
            bookMaterialCleanup: bookMaterialCleanup,
            bookMaterialCleanupByID: bookMaterialCleanupByID,
            prepareBookMaterialCleanup: prepareBookMaterialCleanup,
            withBookDeletionAdmission: withBookDeletionAdmission,
            restoreBookAfterFailedRetirement: restoreBookAfterFailedRetirement,
            scheduleBookRecovery: scheduleBookRecovery,
            retireAndDrainBook: retireAndDrainBook,
            retireAndDrainBookForGeneration: { bookID, _, generation in
                try await retireAndDrainBook?(bookID)
                if withBookDeletionAdmission != nil { #expect(generation == 41) }
            }
        )
    }

    @Test("Remote book tombstone retires and drains source before deleting the local row")
    func remoteTombstoneRetiresBeforeDeletingBook() async throws {
        let book = Book(
            id: UUID(), userId: UUID(), title: "Managed", author: "Author",
            formatType: .pdf, addedAt: Date(), fileURL: "Books/book.pdf"
        )
        let books = StubBookStore()
        await books.seed(book)
        let observedLiveRow = RetireProbe()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: StubMetadata(),
            retireAndDrainBook: { bookID in
                await observedLiveRow.record(try await books.book(bookID) != nil)
            }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(await observedLiveRow.sawLiveBook)
        #expect(try await books.book(book.id) == nil)
    }

    @Test("Inbound deletion drains first and removes the pending attempt staging directory")
    func inboundDeletionCleansPendingStagingAfterDrain() async throws {
        let ownerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Pending", formatType: .epub, fileURL: "Books/\(UUID().uuidString)/pending.epub")
        let books = StubBookStore()
        await books.seed(book)
        let attemptID = UUID()
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: 4, bookID: book.id, attemptID: attemptID)
        let pending = PendingBookMaterialization(
            token: token,
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([1]),
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 10, modificationDate: Date(), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: String(repeating: "a", count: 64),
            expectedByteCount: 10,
            stagingRelativePath: "Imports/\(attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .copying
        )
        let root = URL.temporaryDirectory.appendingPathComponent("ChangeApplier-PendingDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent("Imports/\(attemptID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingFile = stagingDirectory.appendingPathComponent("content.partial")
        try Data("staging".utf8).write(to: stagingFile)
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            fingerprintPersistence: PendingDeletionPersistence(pending: pending)
        )
        let sequence = BookCleanupSequence()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: StubMetadata(),
            prepareBookMaterialCleanup: { bookID, ownerID in
                await sequence.append("capture")
                let cleanup = try await storage.prepareDeletionCleanup(bookID: bookID, ownerID: ownerID)
                return {
                    await sequence.append("cleanup")
                    try await cleanup()
                }
            },
            retireAndDrainBook: { _ in await sequence.append("drained") }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(await sequence.events == ["drained", "capture", "cleanup"])
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
        #expect(try await books.book(book.id) == nil)
    }

    @Test("Account transition waits for admitted inbound deletion through cleanup and ack")
    func accountTransitionWaitsForDeletionAdmission() async throws {
        let ownerID = UUID()
        let nextOwnerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Admitted", formatType: .epub, fileURL: "Books/admitted.epub")
        let books = StubBookStore()
        await books.seed(book)
        let admission = OwnerDeletionAdmission(ownerID: ownerID)
        let cleanupGate = CleanupGate()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            currentUserId: { ownerID },
            prepareBookMaterialCleanup: { _, _ in
                { try await cleanupGate.enterAndWait() }
            },
            withBookDeletionAdmission: { owner, operation in
                try await admission.withAdmission(ownerID: owner, operation: operation)
            },
            retireAndDrainBook: { _ in }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let applyTask = Task { await applier.apply([change], expectedUserId: ownerID) }
        guard await cleanupGate.waitUntilEntered() else {
            await cleanupGate.release()
            let earlyResult = await applyTask.value
            Issue.record("inbound deletion did not reach cleanup; early apply result: \(earlyResult)")
            return
        }
        let switchTask = Task { await admission.switchOwner(to: nextOwnerID) }
        await admission.waitUntilSwitchRequested()

        #expect(await admission.ownerID == ownerID)
        #expect((await metadata.acknowledgedTombstones()).isEmpty)

        await cleanupGate.release()
        let result = await applyTask.value
        await switchTask.value

        #expect(result.applied == 1)
        #expect(await admission.ownerID == nextOwnerID)
        #expect((await metadata.acknowledgedTombstones()).contains { $0.0 == book.id && $0.1 == .book })
    }

    @Test("Inbound deletion CAS failure keeps managed and attempt staging files")
    func inboundDeletionCASFailureKeepsMaterial() async throws {
        let ownerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Race", formatType: .epub, fileURL: "Books/\(UUID().uuidString)/race.epub")
        let books = StubBookStore()
        await books.seed(book)
        await books.rejectNextDelete()
        let attemptID = UUID()
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: 5, bookID: book.id, attemptID: attemptID)
        let pending = PendingBookMaterialization(
            token: token,
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([1]),
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 10, modificationDate: Date(), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: String(repeating: "b", count: 64),
            expectedByteCount: 10,
            stagingRelativePath: "Imports/\(attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .ready
        )
        let root = URL.temporaryDirectory.appendingPathComponent("ChangeApplier-PendingDeleteRace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingDirectory = root.appendingPathComponent("Imports/\(attemptID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingFile = stagingDirectory.appendingPathComponent("content.partial")
        try Data("staging".utf8).write(to: stagingFile)
        let managedFile = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: managedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: managedFile)
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            fingerprintPersistence: PendingDeletionPersistence(pending: pending)
        )
        let sequence = BookCleanupSequence()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: StubMetadata(),
            prepareBookMaterialCleanup: { bookID, ownerID in
                await sequence.append("capture")
                let cleanup = try await storage.prepareDeletionCleanup(bookID: bookID, ownerID: ownerID)
                return {
                    await sequence.append("cleanup")
                    try await cleanup()
                }
            },
            retireAndDrainBook: { _ in await sequence.append("drained") }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let result = await applier.apply([change])

        #expect(result.applied == 0)
        #expect(!result.errors.isEmpty)
        #expect(await sequence.events == ["drained", "capture"])
        #expect(FileManager.default.fileExists(atPath: stagingFile.path))
        #expect(FileManager.default.fileExists(atPath: managedFile.path))
        #expect(try await books.book(book.id) == book)
    }

    @Test("CAS failure with an unfinished import reports that source recovery is required")
    func inboundDeletionCopyingCASFailureIsExplicitlyRecoverable() async throws {
        let ownerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Copying", formatType: .epub, fileURL: "Books/copying.epub")
        let books = StubBookStore()
        await books.seed(book)
        await books.rejectNextDelete()
        let metadata = StubMetadata()
        let recoverySchedule = BookCleanupSequence()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            currentUserId: { ownerID },
            withBookDeletionAdmission: { _, operation in try await operation(41) },
            restoreBookAfterFailedRetirement: { _, generation in
                #expect(generation == 41)
                return false // A registered/copying job cannot be reopened as readable.
            },
            scheduleBookRecovery: { owner, generation in
                #expect(owner == ownerID)
                #expect(generation == 41)
                await recoverySchedule.append("scheduled")
            },
            retireAndDrainBook: { _ in }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let result = await applier.apply([change], expectedUserId: ownerID)

        #expect(result.applied == 0)
        #expect(result.errors.contains { $0.contains("source recovery is required") })
        #expect(await recoverySchedule.events == ["scheduled"])
        #expect(try await books.book(book.id) == book)
        #expect((await metadata.acknowledgedTombstones()).isEmpty)
    }

    @Test("Failure preparing deletion cleanup restores a still-live managed source")
    func inboundDeletionCleanupPreparationFailureRestoresLiveBook() async throws {
        let ownerID = UUID()
        let book = Book(id: UUID(), userId: ownerID, title: "Cleanup failure", formatType: .pdf, fileURL: "Books/live.pdf")
        let books = StubBookStore()
        await books.seed(book)
        let restoreProbe = RetireProbe()
        let applier = makeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: StubMetadata(),
            currentUserId: { ownerID },
            prepareBookMaterialCleanup: { _, _ in throw Issue269TestFailure.unexpectedMaterialization },
            withBookDeletionAdmission: { _, operation in try await operation(41) },
            restoreBookAfterFailedRetirement: { liveBook, generation in
                #expect(liveBook == book)
                #expect(generation == 41)
                await restoreProbe.record(true)
                return true
            },
            retireAndDrainBook: { _ in }
        )
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )

        let result = await applier.apply([change], expectedUserId: ownerID)

        #expect(result.applied == 0)
        #expect(await restoreProbe.sawLiveBook)
        #expect(try await books.book(book.id) == book)
    }

    @Test("searchable-data notifications are delivered on MainActor before apply returns")
    func searchableDataNotificationUsesMainActorAndPrecedesApplyReturn() async throws {
        let ownerID = UUID()
        let probe = SearchableNotificationProbe()
        let observer = NotificationCenter.default.addObserver(
            forName: .rishiSearchableDataDidChange,
            object: nil,
            queue: nil
        ) { _ in
            probe.recordDelivery()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let highlight = Highlight(
            bookId: UUID(), locatorStart: "epubcfi(/6/2)", locatorEnd: "epubcfi(/6/4)",
            color: .yellow, text: "Searchable passage"
        )
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: StubMetadata(),
            currentUserId: { ownerID }
        )

        let result = await applier.apply(
            [try highlightChange(highlight, at: Date(timeIntervalSince1970: 2_000_000_000))],
            expectedUserId: ownerID
        )
        probe.markApplyReturned()

        #expect(result.applied == 1)
        let delivery = probe.snapshot()
        #expect(delivery.delivered)
        #expect(delivery.deliveredOnMainThread)
        #expect(!delivery.applyHadReturnedAtDelivery)
        #expect(delivery.applyReturned)
    }

    @Test("Conflicting inbound file digest cannot replace a local managed book")
    func conflictingRemoteDigestDoesNotReplaceLocalBook() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let local = Book(
            id: bookID, userId: ownerID, title: "Local title", author: "Author",
            formatType: .epub, fileURL: "Books/local/current.epub"
        )
        let remote = Book(
            id: bookID, userId: ownerID, title: "Remote title", author: "Author",
            formatType: .epub, fileURL: "Books/remote/replacement.epub"
        )
        let books = StubBookStore()
        await books.seed(local)
        let applier = ChangeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            bookmarkStore: StubBookmarkStore(),
            metadataStore: StubMetadata(),
            currentUserId: { ownerID },
            bookMaterializer: { _, _, _ in throw Issue269TestFailure.unexpectedMaterialization },
            managedFingerprintLookup: { _ in
                BookFileFingerprint(
                    bookID: bookID,
                    ownerID: ownerID,
                    sha256: String(repeating: "a", count: 64),
                    version: ManagedFileVersion(byteCount: 12, modificationDate: Date(), fileIdentifier: "local", materializationRevision: UUID())
                )
            }
        )
        let payload = try SyncPayloadCodec.encodeBook(remote, r2Key: "remote-key", fileHash: String(repeating: "b", count: 64), fileSize: 13)
        let change = SyncChange(kind: SyncEntityKind.book.rawValue, id: bookID, payload: payload, updatedAt: Date(), deleted: false)

        let result = await applier.apply([change], expectedUserId: ownerID)

        #expect(result.conflicts == 1)
        #expect(try await books.book(bookID) == local)
    }

    @Test("Matching inbound metadata patches retain the existing local destination")
    func inboundMetadataPatchPreservesLocalDestination() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let local = Book(
            id: bookID, userId: ownerID, title: "Before", author: "Author",
            formatType: .epub, openedAt: Date(timeIntervalSince1970: 50), fileURL: "Books/local/current.epub"
        )
        let remote = Book(
            id: bookID, userId: ownerID, title: "After", author: "Author",
            formatType: .pdf, fileURL: "Books/remote/other.pdf"
        )
        let digest = String(repeating: "c", count: 64)
        let books = StubBookStore()
        await books.seed(local)
        let applier = ChangeApplier(
            bookStore: books,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            bookmarkStore: StubBookmarkStore(),
            metadataStore: StubMetadata(),
            currentUserId: { ownerID },
            managedFingerprintLookup: { _ in
                BookFileFingerprint(
                    bookID: bookID,
                    ownerID: ownerID,
                    sha256: digest,
                    version: ManagedFileVersion(byteCount: 9, modificationDate: Date(), fileIdentifier: "local", materializationRevision: UUID())
                )
            }
        )
        let payload = try SyncPayloadCodec.encodeBook(remote, r2Key: nil, fileHash: digest, fileSize: 9)
        let change = SyncChange(kind: SyncEntityKind.book.rawValue, id: bookID, payload: payload, updatedAt: Date(), deleted: false)

        let result = await applier.apply([change], expectedUserId: ownerID)

        let patched = try #require(await books.book(bookID))
        #expect(result.applied == 1)
        #expect(patched.title == "After")
        #expect(patched.fileURL == local.fileURL)
        #expect(patched.formatType == local.formatType)
        #expect(patched.openedAt == local.openedAt)
    }

    private enum Issue269TestFailure: Error { case unexpectedMaterialization, ownerChanged }

    private func positionChange(_ position: Position, at: Date) throws -> SyncChange {
        let payload = try SyncPayloadCodec.encodePosition(position)
        return SyncChange(
            kind: SyncEntityKind.position.rawValue,
            id: position.id,
            payload: payload,
            updatedAt: at,
            deleted: false
        )
    }

    private func highlightChange(_ highlight: Highlight, at: Date, deleted: Bool = false) throws -> SyncChange {
        let payload = try SyncPayloadCodec.encodeHighlight(highlight)
        return SyncChange(
            kind: SyncEntityKind.highlight.rawValue,
            id: highlight.id,
            payload: payload,
            updatedAt: at,
            deleted: deleted
        )
    }

    // MARK: - Tests (≥6 required by plan)

    @Test("Inbound changes for a different account are rejected without mutating stores")
    func inboundChangeForDifferentAccountIsRejected() async throws {
        let expectedUserId = UUID()
        let activeUserId = UUID()
        let position = Position(
            bookId: UUID(),
            locator: "pdf-v1:page:12",
            percentComplete: 0.4,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let positionStore = StubPositionStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            currentUserId: { activeUserId }
        )

        let change = try positionChange(position, at: position.updatedAt)
        let result = await applier.apply([change], expectedUserId: expectedUserId)

        #expect(result.applied == 0)
        #expect(result.errors.contains("account switched during inbound sync"))
        #expect(await positionStore.snapshot().isEmpty)
        #expect(await metadata.cleaned().isEmpty)
    }

    @Test("Position: local newer than remote → conflict, no overwrite")
    func positionLocalNewerWins() async throws {
        let bookId = UUID()
        let localPosition = Position(
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let remotePosition = Position(
            id: localPosition.id,
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let positionStore = StubPositionStore()
        await positionStore.seed(localPosition)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let change = try positionChange(remotePosition, at: remotePosition.updatedAt)
        let result = await applier.apply([change])

        #expect(result.conflicts == 1)
        #expect(result.applied == 0)

        let stored = await positionStore.snapshot()
        #expect(stored.first?.locator == "pdf-v1:page:10")
        #expect(stored.first?.percentComplete == 0.5)
    }

    @Test("Local-wins conflict records remote seen without clearing local work")
    func localWinsRecordsRemoteSeen() async throws {
        let positionStore = StubPositionStore()
        let bookId = UUID()
        let local = Position(
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        await positionStore.seed(local)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )
        let remote = Position(
            bookId: bookId,
            locator: "pdf-v1:page:2",
            percentComplete: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        _ = await applier.apply([try positionChange(remote, at: remote.updatedAt)])

        let seen = await metadata.remoteSeen()
        #expect(seen.count == 1)
        #expect(seen.first?.0 == bookId)
        #expect(seen.first?.1 == .position)
    }

    @Test("Duplicate remote replay records remote seen")
    func duplicateRemoteReplayRecordsRemoteSeen() async throws {
        let positionStore = StubPositionStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )
        let position = Position(
            bookId: UUID(),
            locator: "pdf-v1:page:4",
            percentComplete: 0.2,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let change = try positionChange(position, at: position.updatedAt)

        _ = await applier.apply([change])
        _ = await applier.apply([change])

        #expect((await metadata.remoteSeen()).count == 1)
    }

    @Test("Position: remote newer than local → upsert remote + markClean")
    func positionRemoteNewerWins() async throws {
        let bookId = UUID()
        let localPosition = Position(
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let remotePosition = Position(
            id: localPosition.id,
            bookId: bookId,
            locator: "pdf-v1:page:10",
            percentComplete: 0.5,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let positionStore = StubPositionStore()
        await positionStore.seed(localPosition)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: positionStore,
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let change = try positionChange(remotePosition, at: remotePosition.updatedAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)

        let stored = await positionStore.snapshot()
        #expect(stored.first?.locator == "pdf-v1:page:10")
        #expect(stored.first?.percentComplete == 0.5)

        // markClean uses change.updatedAt as the cursor against bookId.
        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 1)
        #expect(cleaned[0].0 == bookId)
        #expect(cleaned[0].1 == .position)
        #expect(cleaned[0].2.timeIntervalSince1970 == 2_000_000_000)
    }

    @Test("Highlight: new ID remote-only → upserted")
    func highlightNewRemoteIdUpserted() async throws {
        let highlightStore = StubHighlightStore()
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let remote = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "remote-only"
        )
        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        #expect(stored.count == 1)
        #expect(stored.first?.id == remote.id)
    }

    @Test("Highlight: new ID local-only → kept (no change for that id)")
    func highlightNewLocalIdSurvives() async throws {
        let highlightStore = StubHighlightStore()
        let local = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "local-only"
        )
        await highlightStore.seed(local)

        // Remote sends a DIFFERENT id — different highlight, both survive.
        let remote = Highlight(
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi-b",
            locatorEnd: "epub-v1:cfi-b",
            color: .blue,
            text: "remote-different-id"
        )
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        // BOTH ids present — merge-by-id semantics keep distinct ids.
        let ids = Set(stored.map(\.id))
        #expect(ids == Set([local.id, remote.id]))
    }

    @Test("Highlight: same ID, local newer (createdAt) → conflict, no overwrite")
    func highlightSameIdLocalNewerWins() async throws {
        let highlightStore = StubHighlightStore()
        let highlightId = UUID()
        let local = Highlight(
            id: highlightId,
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "newer-local",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        await highlightStore.seed(local)

        let remote = Highlight(
            id: highlightId,
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .green,
            text: "older-remote",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )

        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.conflicts == 1)
        #expect(result.applied == 0)
        let stored = await highlightStore.snapshot()
        #expect(stored.first?.text == "newer-local")
        #expect(stored.first?.color == .pink)
    }

    @Test("Highlight: same ID, remote newer → overwrites local")
    func highlightSameIdRemoteNewerWins() async throws {
        let highlightStore = StubHighlightStore()
        let highlightId = UUID()
        let local = Highlight(
            id: highlightId,
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .pink,
            text: "older-local",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        await highlightStore.seed(local)

        let remote = Highlight(
            id: highlightId,
            bookId: local.bookId,
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .green,
            text: "newer-remote",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(remote, at: remote.createdAt)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        let stored = await highlightStore.snapshot()
        #expect(stored.first?.text == "newer-remote")
        #expect(stored.first?.color == .green)
    }

    @Test("Highlight: deleted=true → highlightStore.delete + metadata.forget")
    func highlightTombstoneDeletes() async throws {
        let highlightStore = StubHighlightStore()
        let local = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "to-delete"
        )
        await highlightStore.seed(local)
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: highlightStore,
            metadata: metadata
        )

        let change = try highlightChange(local, at: Date(), deleted: true)
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let stored = await highlightStore.snapshot()
        #expect(stored.isEmpty)
        // Remote tombstones retain a clean metadata barrier so an older
        // cursor cannot resurrect the deleted highlight.
        let acknowledged = await metadata.acknowledgedTombstones()
        #expect(acknowledged.count == 1)
        #expect(acknowledged[0].0 == local.id)
        #expect(acknowledged[0].1 == .highlight)
    }

    @Test("Book: deleted=true tombstone → bookStore.delete + retained metadata barrier")
    func bookDeletedTombstone() async throws {
        let bookStore = StubBookStore()
        let book = Book(
            userId: UUID(),
            title: "Doomed",
            formatType: .epub,
            fileURL: "Books/x.epub"
        )
        await bookStore.seed(book)
        let metadata = StubMetadata()
        let cleanup = CleanupProbe()
        let applier = makeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata,
            bookMaterialCleanup: { book in await cleanup.record(book.id) }
        )

        // Tombstone — payload is irrelevant for delete path.
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )
        let result = await applier.apply([change])

        #expect(result.applied == 1)
        let count = await bookStore.count()
        #expect(count == 0)
        #expect(await cleanup.snapshot() == [book.id])
        let acknowledged = await metadata.acknowledgedTombstones()
        #expect(acknowledged.count == 1)
        #expect(acknowledged.first?.0 == book.id)
        #expect(acknowledged.first?.1 == .book)
    }

    @Test("verified inbound Book is retried until its fingerprint is persisted")
    func inboundBookRetriesUntilFingerprintIsPersisted() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let digest = String(repeating: "a", count: 64)
        let remote = Book(id: bookID, userId: ownerID, title: "Remote", formatType: .epub, fileURL: "books/remote.epub")
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: bookID,
            payload: try SyncPayloadCodec.encodeBook(remote, r2Key: "books/remote.epub", fileHash: digest, fileSize: 8),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            deleted: false
        )
        let managed = Book(id: bookID, userId: ownerID, title: "Remote", formatType: .epub, fileURL: "books/managed.epub")
        let fingerprint = BookFileFingerprint(
            bookID: bookID,
            ownerID: ownerID,
            sha256: digest,
            version: ManagedFileVersion(byteCount: 8, modificationDate: Date(timeIntervalSince1970: 1_800_000_000), fileIdentifier: "managed", materializationRevision: UUID())
        )
        let verified = VerifiedDownloadedBook(book: managed, fingerprint: fingerprint)
        let persistence = FingerprintPersistProbe(answers: [false, true])
        let bookStore = StubBookStore()
        let metadata = StubMetadata()
        let applier = ChangeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            bookmarkStore: StubBookmarkStore(),
            metadataStore: metadata,
            currentUserId: { ownerID },
            bookMaterializer: { _, _, remoteFile in
                guard remoteFile?.sha256 == digest, remoteFile?.byteCount == 8 else {
                    throw SwiftDataTestFailure.invalidRemoteMetadata
                }
                return verified
            },
            bookFingerprintPersister: { _, candidate, _ in
                guard candidate == fingerprint else { return false }
                return await persistence.persist()
            }
        )

        let first = await applier.apply([change], expectedUserId: ownerID)
        #expect(first.applied == 0)
        #expect(!first.errors.isEmpty)
        #expect(await bookStore.count() == 1)
        #expect((await metadata.cleaned()).isEmpty)

        let retry = await applier.apply([change], expectedUserId: ownerID)
        #expect(retry.applied == 1)
        #expect(retry.errors.isEmpty)
        #expect(await bookStore.count() == 1)
        #expect((await metadata.cleaned()).count == 1)
        #expect(await persistence.calls == 2)
    }

    @Test("new inbound acceptance rejects the captured account generation after relogin")
    func newInboundAcceptanceUsesCapturedAccountPermit() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let digest = String(repeating: "a", count: 64)
        let remote = Book(id: bookID, userId: ownerID, title: "Remote", formatType: .epub, fileURL: "books/remote.epub")
        let operationID = UUID()
        let change = SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: bookID,
            operationId: operationID,
            payload: try SyncPayloadCodec.encodeBook(remote, r2Key: "books/remote.epub", fileHash: digest, fileSize: 8),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            deleted: false
        )
        let managed = Book(id: bookID, userId: ownerID, title: "Remote", formatType: .epub, fileURL: "books/managed.epub")
        let fingerprint = BookFileFingerprint(
            bookID: bookID,
            ownerID: ownerID,
            sha256: digest,
            version: ManagedFileVersion(byteCount: 8, modificationDate: Date(timeIntervalSince1970: 1_800_000_000), fileIdentifier: "managed", materializationRevision: UUID())
        )
        let state = InboundAccountPermitProbe()
        let bookStore = StubBookStore()
        let metadata = StubMetadata()
        let applier = ChangeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            bookmarkStore: StubBookmarkStore(),
            metadataStore: metadata,
            currentUserId: { ownerID },
            bookMaterializer: { _, _, _ in
                await state.advanceGeneration()
                return VerifiedDownloadedBook(book: managed, fingerprint: fingerprint)
            },
            bookFingerprintPersister: { _, candidate, capturedGeneration in
                candidate == fingerprint && capturedGeneration == 1
            },
            bookAccountPermitLookup: { await state.permit(ownerID: ownerID) },
            newBookServerAcceptancePersister: { permit, candidate, _ in
                guard candidate == fingerprint else { return false }
                let currentGeneration = await state.currentGeneration()
                return permit.accountGeneration == currentGeneration
            }
        )

        let result = await applier.apply([change], expectedUserId: ownerID)

        #expect(result.applied == 0)
        #expect(!result.errors.isEmpty)
        #expect((await metadata.cleaned()).isEmpty)
        #expect(await state.capturedPermit()?.accountGeneration == 1)
        #expect(await state.currentGeneration() == 2)
    }

    @Test("authority materializer retains the original permit for both existing and absent books", arguments: [false, true])
    func staleAuthorityResponseNeverBeginsCanonicalCommit(existing: Bool) async throws {
        let owner = UUID()
        let remote = Book(userId: owner, title: "Remote", formatType: .epub, fileURL: "Books/remote.epub")
        let local = Book(id: remote.id, userId: owner, title: "Local", formatType: .epub, fileURL: "Books/local.epub")
        let digest = String(repeating: "c", count: 64)
        let fingerprint = BookFileFingerprint(bookID: remote.id, ownerID: owner, sha256: digest,
            version: ManagedFileVersion(byteCount: 8, modificationDate: Date(), fileIdentifier: "verified", materializationRevision: UUID()))
        let account = InboundAccountPermitProbe()
        let stages = CommitStageProbe()
        let books = StubBookStore()
        if existing { await books.seed(local) }
        let positions = StubPositionStore()
        let metadata = StubMetadata()
        let applier = ChangeApplier(bookStore: books, positionStore: positions,
            highlightStore: StubHighlightStore(), bookmarkStore: StubBookmarkStore(), metadataStore: metadata,
            currentUserId: { owner },
            bookMaterializerWithAuthority: { _, _, _, captured in
                #expect(captured.ownerID == owner)
                #expect(captured.accountGeneration == 1)
                await stages.record("response-g1")
                await account.advanceGeneration()
                return VerifiedDownloadedBook(book: remote, fingerprint: fingerprint)
            },
            isCurrentAccountPermit: { captured in
                let current = await account.currentGeneration()
                return captured.ownerID == owner && captured.accountGeneration == current
            },
            admitAccountOperation: { _ in await stages.record("admission"); return nil },
            bookFingerprintPersister: { _, _, _ in await stages.record("fingerprint"); return true },
            activateBookWithAuthority: { _, _ in await stages.record("activation") },
            bookAccountPermitLookup: { await account.permit(ownerID: owner) },
            newBookServerAcceptancePersister: { _, _, _ in await stages.record("acceptance"); return true }
        )
        let payload = try SyncPayloadCodec.encodeBook(remote, r2Key: "owned/remote", position: Position(bookId: remote.id, locator: "epub-v1:remote", percentComplete: 0.8), fileHash: digest, fileSize: 8)
        let result = await applier.apply([SyncChange(kind: SyncEntityKind.book.rawValue, id: remote.id, operationId: UUID(), payload: payload, updatedAt: Date(), deleted: false)], expectedUserId: owner)
        #expect(result.applied == 0)
        #expect(!result.errors.isEmpty)
        #expect(try await books.book(remote.id) == (existing ? local : nil))
        #expect((await positions.snapshot()).isEmpty)
        #expect((await metadata.cleaned()).isEmpty)
        #expect(await stages.snapshot() == ["response-g1"])
        #expect(await account.capturedPermit()?.accountGeneration == 1)
        #expect(await account.currentGeneration() == 2)
    }

    @Test("generation replacement during an entered fingerprint commit suppresses later stages")
    func enteredCanonicalStageDoesNotStartLaterStagesAfterReplacement() async throws {
        let owner = UUID()
        let remote = Book(userId: owner, title: "Entered commit", formatType: .epub, fileURL: "Books/entered.epub")
        let digest = String(repeating: "d", count: 64)
        let fingerprint = BookFileFingerprint(bookID: remote.id, ownerID: owner, sha256: digest,
            version: ManagedFileVersion(byteCount: 8, modificationDate: Date(), fileIdentifier: "entered", materializationRevision: UUID()))
        let account = InboundAccountPermitProbe()
        let stages = CommitStageProbe()
        let books = StubBookStore()
        let positions = StubPositionStore()
        let metadata = StubMetadata()
        let applier = ChangeApplier(bookStore: books, positionStore: positions,
            highlightStore: StubHighlightStore(), bookmarkStore: StubBookmarkStore(), metadataStore: metadata,
            currentUserId: { owner },
            bookMaterializerWithAuthority: { _, _, _, captured in
                #expect(captured.accountGeneration == 1)
                return VerifiedDownloadedBook(book: remote, fingerprint: fingerprint)
            },
            isCurrentAccountPermit: { captured in let current = await account.currentGeneration()
                return captured.ownerID == owner && captured.accountGeneration == current },
            bookFingerprintPersister: { _, _, generation in
                #expect(generation == 1)
                await stages.record("entered-fingerprint-g1")
                await account.advanceGeneration()
                return true
            },
            activateBookWithAuthority: { _, _ in await stages.record("activation") },
            bookAccountPermitLookup: { await account.permit(ownerID: owner) },
            newBookServerAcceptancePersister: { _, _, _ in await stages.record("acceptance"); return true }
        )
        let payload = try SyncPayloadCodec.encodeBook(remote, r2Key: "owned/entered", position: Position(bookId: remote.id, locator: "epub-v1:entered", percentComplete: 0.8), fileHash: digest, fileSize: 8)
        let result = await applier.apply([SyncChange(kind: SyncEntityKind.book.rawValue, id: remote.id, operationId: UUID(), payload: payload, updatedAt: Date(), deleted: false)], expectedUserId: owner)
        #expect(result.applied == 0)
        #expect(!result.errors.isEmpty)
        #expect(try await books.book(remote.id) == remote)
        #expect((await positions.snapshot()).isEmpty)
        #expect((await metadata.cleaned()).isEmpty)
        #expect(await stages.snapshot() == ["entered-fingerprint-g1"])
    }

    private enum SwiftDataTestFailure: Error { case invalidRemoteMetadata }

    @Test("Book: remote tombstone wins over a stale local live mutation")
    func remoteBookDeleteClearsStaleDirtyLocalCopy() async throws {
        let bookStore = StubBookStore()
        let book = Book(
            userId: UUID(),
            title: "Imported before remote delete",
            formatType: .epub,
            fileURL: "Books/stale.epub"
        )
        await bookStore.seed(book)
        let metadata = StubMetadata()
        await metadata.seedDirty(book.id, kind: .book)
        let applier = makeApplier(
            bookStore: bookStore,
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let result = await applier.apply([SyncChange(
            kind: SyncEntityKind.book.rawValue,
            id: book.id,
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(),
            deleted: true
        )])

        #expect(result.applied == 1)
        #expect(result.conflicts == 0)
        #expect(await bookStore.count() == 0)
        #expect((await metadata.acknowledgedTombstones()).contains { $0.0 == book.id && $0.1 == .book })
    }

    /// Phase 16-05 regression guard: chat sync moved to dedicated
    /// `/api/sync/conversations` + `/api/sync/messages` endpoints driven
    /// directly by `SyncEngine.runOnce` (bypassing `ChangeApplier`). The
    /// legacy `.conversation` / `.message` branch in `ChangeApplier.apply`
    /// is preserved as a defensive markClean no-op so any row that DOES
    /// somehow arrive via the legacy `/api/sync/changes` envelope still
    /// advances the cursor instead of looping. This test pins that branch.
    @Test("Phase 16-05 regression: legacy SyncChange.conversation still skipped + markClean'd")
    func phase16LegacyConversationStillSkipped() async throws {
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let convoChange = SyncChange(
            kind: SyncEntityKind.conversation.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            deleted: false
        )

        let result = await applier.apply([convoChange])
        #expect(result.skipped == 1)
        #expect(result.applied == 0)
        #expect(result.errors.isEmpty)

        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 1)
        #expect(cleaned[0].1 == .conversation)
    }

    @Test("Conversation + Message kinds → skipped (Phase 9) but markClean still called")
    func phase9KindsAreSkippedNotErrored() async throws {
        let metadata = StubMetadata()
        let applier = makeApplier(
            bookStore: StubBookStore(),
            positionStore: StubPositionStore(),
            highlightStore: StubHighlightStore(),
            metadata: metadata
        )

        let convoChange = SyncChange(
            kind: SyncEntityKind.conversation.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deleted: false
        )
        let msgChange = SyncChange(
            kind: SyncEntityKind.message.rawValue,
            id: UUID(),
            payload: SyncOpaqueJSON(data: Data("{}".utf8)),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            deleted: false
        )

        let result = await applier.apply([convoChange, msgChange])
        #expect(result.skipped == 2)
        #expect(result.applied == 0)
        #expect(result.errors.isEmpty)

        let cleaned = await metadata.cleaned()
        #expect(cleaned.count == 2)
        #expect(Set(cleaned.map(\.1)) == Set([.conversation, .message]))
    }
}

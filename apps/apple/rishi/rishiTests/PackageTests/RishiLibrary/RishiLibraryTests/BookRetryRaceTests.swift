import CryptoKit
import Foundation
import Testing
@testable import rishi

@Suite("Book retry ownership races")
struct BookRetryRaceTests {
    @Test("recovered paused job retries selected matching bytes without old managed bytes or an in-memory token")
    func recoveredPausedJobRetriesSelectedBytes() async throws {
        let fixture = try await RetryRaceFixture.make()
        defer { fixture.cleanup() }
        let selectedURL = try fixture.makeSelectedStage(named: "selected", bytes: fixture.bytes)
        let expectation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id,
            ownerID: fixture.ownerID,
            accountPermit: fixture.accountPermit
        ))
        #expect(expectation.pending.token == fixture.oldToken)
        #expect(expectation.pending.phase == .paused)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))
        #expect(try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 0) == nil)

        let next = try fixture.pendingSource(for: selectedURL, name: "recovered")
        let retry = try await fixture.coordinator.retryAndRegisterReadableSource(
            book: fixture.book,
            accountPermit: fixture.accountPermit,
            retryExpectation: expectation,
            newSource: next,
            retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
            sourceURL: selectedURL,
            requiresSecurityScope: false
        )

        #expect(retry.registration.token == next.token)
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.ownerID)?.token == next.token)
        #expect(try #require(await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 1)).contentRevision == fixture.canonicalRevision)
        #expect(try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 0) == nil)

        let ready = try await fixture.coordinator.materialize(
            book: fixture.book,
            token: next.token,
            sourceURL: selectedURL,
            reuseRegisteredSource: true,
            admission: retry.admission
        )
        #expect(ready.sha256 == fixture.digest)
        #expect(try Data(contentsOf: fixture.managedURL) == fixture.bytes)
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.ownerID)?.phase == .ready)
        await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 1)
    }

    @Test("authority invalidation during selected-source proof prevents retry CAS and publication", arguments: RetryProofInvalidation.allCases)
    fileprivate func invalidationDuringHeldSelectedProofDeniesRetry(_ invalidation: RetryProofInvalidation) async throws {
        let fixture = try await RetryRaceFixture.make()
        defer { fixture.cleanup() }
        let selectedURL = try fixture.makeSelectedStage(named: "held", bytes: fixture.bytes)
        let expectation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id,
            ownerID: fixture.ownerID,
            accountPermit: fixture.accountPermit
        ))
        let gate = RetryRaceGate()
        let scopeProbe = RetryRaceScopeProbe()
        let coordinator = fixture.makeCoordinator(reprobe: { url, revision in
            #expect(scopeProbe.isActive)
            try await gate.holdAtProof()
            let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: revision)
            return (result.sha256, result.byteCount, result.version)
        }, scopeProbe: scopeProbe)
        let next = try fixture.pendingSource(for: selectedURL, name: "invalidation-loser")
        let retry = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: fixture.book,
                accountPermit: fixture.accountPermit,
                retryExpectation: expectation,
                newSource: next,
                retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                sourceURL: selectedURL,
                requiresSecurityScope: true
            )
        }
        defer {
            retry.cancel()
            Task { await gate.release() }
        }
        _ = try #require(await gate.waitUntilEntered())
        switch invalidation {
        case .tombstone:
            try await fixture.persistence.setBookReadingAuthorization(
                bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 0,
                contentRevision: fixture.canonicalRevision, tombstoned: true
            )
        case .revoked:
            try await fixture.dbStore.revokeBookReading(
                permit: BookReadingPermit(ownerID: fixture.ownerID, accountGeneration: 0,
                                          bookID: fixture.book.id, contentRevision: fixture.canonicalRevision)
            )
        case .accountGenerationChanged:
            try await fixture.persistence.setAccountAuthorization(ownerID: fixture.ownerID, generation: 2)
            await fixture.generation.set(2)
        case .bookRetired:
            fixture.lifecycle.retireBook(ownerID: fixture.ownerID, generation: 1, bookID: fixture.book.id)
        }
        await gate.release()
        await #expect(throws: Error.self) { _ = try await boundedValue(retry, gate: gate) }

        if invalidation == .bookRetired {
            await fixture.lifecycle.drainBook(ownerID: fixture.ownerID, generation: 1, bookID: fixture.book.id)
        } else {
            await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 1)
        }
        #expect(scopeProbe.counts == (starts: 1, stops: 1, active: 0))
        let pendingAfterRetry = try await fixture.persistence.pendingMaterializationForDeletionCleanup(bookID: fixture.book.id, ownerID: fixture.ownerID)
        if invalidation == .bookRetired {
            #expect(pendingAfterRetry?.token == next.token)
            #expect(pendingAfterRetry?.phase == .paused)
        } else {
            #expect(pendingAfterRetry == expectation.pending)
            #expect(try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 1) == nil)
        }
        if invalidation == .tombstone || invalidation == .revoked {
            #expect(try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 0) == nil)
        }
        if invalidation == .accountGenerationChanged {
            await #expect(throws: SwiftDataBookImportPersistence.PersistenceError.unauthorized) {
                _ = try await fixture.persistence.retryExpectation(
                    bookID: fixture.book.id, ownerID: fixture.ownerID, accountPermit: fixture.accountPermit
                )
            }
        } else {
            let retryableAfterRace = try await fixture.persistence.retryExpectation(
                bookID: fixture.book.id, ownerID: fixture.ownerID, accountPermit: fixture.accountPermit
            )
            if invalidation == .bookRetired {
                #expect(retryableAfterRace?.pending.token == next.token)
            } else {
                #expect(retryableAfterRace == nil)
            }
        }
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        await #expect(throws: Error.self) {
            _ = try await fixture.registry.acquireReadableSource(for: fixture.book)
        }
        if invalidation == .bookRetired {
            let retiredToken = BookMaterializationToken(ownerID: fixture.ownerID, accountGeneration: 1,
                                                        bookID: fixture.book.id, attemptID: UUID())
            #expect(fixture.lifecycle.admitBookMaterialization(retiredToken) == nil)
        }
    }

    @Test("caller cancellation while selected proof is held leaves the retry witness unchanged")
    func cancellationBeforeRetryCASLeavesWitnessUnchanged() async throws {
        let fixture = try await RetryRaceFixture.make()
        defer { fixture.cleanup() }
        let selectedURL = try fixture.makeSelectedStage(named: "cancel-before-cas", bytes: fixture.bytes)
        let expectation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id, ownerID: fixture.ownerID, accountPermit: fixture.accountPermit
        ))
        let gate = RetryRaceGate()
        let scopeProbe = RetryRaceScopeProbe()
        let coordinator = fixture.makeCoordinator(reprobe: { url, revision in
            try await gate.holdAtProof()
            let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: revision)
            return (result.sha256, result.byteCount, result.version)
        }, scopeProbe: scopeProbe)
        let source = try fixture.pendingSource(for: selectedURL, name: "cancelled-before-cas")
        let retry = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
                newSource: source, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                sourceURL: selectedURL, requiresSecurityScope: true
            )
        }
        defer {
            retry.cancel()
            Task { await gate.release() }
        }

        _ = try #require(await gate.waitUntilEntered())
        retry.cancel()
        await gate.release()
        await #expect(throws: Error.self) { _ = try await boundedValue(retry, gate: gate) }

        #expect(try await fixture.persistence.pendingMaterializationForDeletionCleanup(bookID: fixture.book.id, ownerID: fixture.ownerID) == expectation.pending)
        let retryAfterCancellation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id, ownerID: fixture.ownerID, accountPermit: fixture.accountPermit
        ))
        #expect(retryAfterCancellation.pending == expectation.pending)
        #expect(retryAfterCancellation.readingPermit == expectation.readingPermit)
        #expect(try await fixture.persistence.readingPermit(
            bookID: fixture.book.id, ownerID: fixture.ownerID, generation: 1
        ) == nil)
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        #expect(scopeProbe.counts == (starts: 1, stops: 1, active: 0))
        await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 1)
    }

    @Test("sibling retry contestant cannot retire the winner or remove its selected staging bytes")
    func siblingRetryContestantCannotRetireWinningStage() async throws {
        let fixture = try await RetryRaceFixture.make()
        defer { fixture.cleanup() }
        let firstURL = try fixture.makeSelectedStage(named: "winner-stage", bytes: fixture.bytes)
        let secondURL = try fixture.makeSelectedStage(named: "loser-stage", bytes: fixture.bytes)
        let expectation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id,
            ownerID: fixture.ownerID,
            accountPermit: fixture.accountPermit
        ))
        let gate = RetryRaceGate()
        let coordinator = fixture.makeCoordinator(reprobe: { url, revision in
            try await gate.holdAtProof()
            let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: revision)
            return (result.sha256, result.byteCount, result.version)
        })
        let winner = try fixture.pendingSource(for: firstURL, name: "winner")
        let loser = try fixture.pendingSource(for: secondURL, name: "sibling")
        let winningRetry = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
                newSource: winner, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                sourceURL: firstURL, requiresSecurityScope: false
            )
        }
        defer {
            winningRetry.cancel()
            Task { await gate.release() }
        }
        _ = try #require(await gate.waitUntilEntered())

        let siblingRetry = Task<Bool, Error> {
            do {
                _ = try await coordinator.retryAndRegisterReadableSource(
                    book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
                    newSource: loser, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                    sourceURL: secondURL, requiresSecurityScope: false
                )
                return false
            } catch {
                return true
            }
        }
        #expect(try await boundedValue(siblingRetry))
        #expect(try Data(contentsOf: firstURL) == fixture.bytes)

        await gate.release()
        let won = try await boundedValue(winningRetry, gate: gate)
        #expect(won.registration.token == winner.token)
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.ownerID)?.token == winner.token)
        #expect(try Data(contentsOf: firstURL) == fixture.bytes)
        #expect(try Data(contentsOf: secondURL) == fixture.bytes)

        let staleContestant = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
                newSource: loser, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                sourceURL: secondURL, requiresSecurityScope: false
            )
        }
        await #expect(throws: Error.self) { _ = try await boundedValue(staleContestant) }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.ownerID)?.token == winner.token)
        #expect(try Data(contentsOf: firstURL) == fixture.bytes)
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        won.admission.release()
        await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 1)
    }

    @Test("retry cannot bypass a live older-generation materialization admission")
    func retryWaitsForOlderGenerationAttemptToDrain() async throws {
        let fixture = try await RetryRaceFixture.make(holdOldAttempt: true)
        defer { fixture.cleanup() }
        let heldOldAttempt = try #require(fixture.oldAttemptAdmission)
        let promotionGate = try #require(fixture.oldPromotionGate)
        let promotionCompletion = try #require(fixture.oldPromotionCompletion)
        let promotionTask = try #require(fixture.oldPromotionTask)
        #expect(!(await promotionCompletion.isComplete()))
        #expect(try await fixture.persistence.pendingMaterializationForDeletionCleanup(bookID: fixture.book.id, ownerID: fixture.ownerID)?.token == fixture.oldToken)

        let selectedURL = try fixture.makeSelectedStage(named: "after-drain", bytes: fixture.bytes)
        let expectation = try #require(await fixture.persistence.retryExpectation(
            bookID: fixture.book.id,
            ownerID: fixture.ownerID,
            accountPermit: fixture.accountPermit
        ))
        let next = try fixture.pendingSource(for: selectedURL, name: "post-drain")
        let retryStarted = RetryRaceCompletion()
        let blockedRetry = Task {
            await retryStarted.markStarted()
            do {
                let result = try await fixture.coordinator.retryAndRegisterReadableSource(
                    book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
                    newSource: next, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
                    sourceURL: selectedURL, requiresSecurityScope: false
                )
                await retryStarted.markComplete()
                return result
            } catch {
                await retryStarted.markComplete()
                throw error
            }
        }
        #expect(await retryStarted.waitUntilStarted())
        await #expect(throws: RetryRaceGateError.timedOut) {
            _ = try await boundedValue(blockedRetry, timeout: .seconds(4))
        }
        #expect(!(await retryStarted.isComplete()))
        #expect(try await fixture.persistence.pendingMaterializationForDeletionCleanup(bookID: fixture.book.id, ownerID: fixture.ownerID) == expectation.pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))

        await promotionGate.release()
        #expect(await promotionCompletion.waitUntilComplete())
        heldOldAttempt.release()
        let drained = RetryRaceCompletion()
        let drainTask = Task {
            await drained.markStarted()
            await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 0)
            await drained.markComplete()
        }
        #expect(await drained.waitUntilStarted())
        #expect(await drained.waitUntilComplete())
        await #expect(throws: CancellationError.self) { _ = try await blockedRetry.value }
        #expect(await retryStarted.waitUntilComplete())

        let retried = try await fixture.coordinator.retryAndRegisterReadableSource(
            book: fixture.book, accountPermit: fixture.accountPermit, retryExpectation: expectation,
            newSource: next, retiredAttempt: RetiredBookMaterializationAttempt(token: fixture.oldToken),
            sourceURL: selectedURL, requiresSecurityScope: false
        )
        #expect(retried.registration.token == next.token)
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.ownerID)?.token == next.token)
        retried.admission.release()
        await fixture.lifecycle.drainAccount(fixture.ownerID, generation: 1)
    }
}

private struct RetryRaceFixture {
    let rootURL: URL
    let sourceURL: URL
    let managedURL: URL
    let bytes: Data
    let digest: String
    let ownerID: UUID
    let canonicalRevision: UUID
    let book: Book
    let oldToken: BookMaterializationToken
    let persistence: SwiftDataBookImportPersistence
    let books: SwiftDataBookStore
    let generation: RetryRaceGeneration
    let registry: BookSourceRegistry
    let lifecycle: BookImportLifecycle
    let coordinator: BookMaterializationCoordinator
    let accountPermit: AccountMutationPermit
    let oldAttemptAdmission: BookImportMaterializationAdmission?
    let oldPromotionGate: RetryRaceGate?
    let oldPromotionCompletion: RetryRaceCompletion?
    let oldPromotionTask: Task<Void, Never>?
    let dbStore: RishiDBStore

    static func make(holdOldAttempt: Bool = false) async throws -> RetryRaceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-race-\(UUID())", isDirectory: true)
        let sourceURL = root.appendingPathComponent("provider/original.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("selected verified retry bytes".utf8)
        try bytes.write(to: sourceURL)
        let ownerID = UUID()
        let revision = UUID()
        let book = Book(userId: ownerID, title: "Retry race", formatType: .epub, fileURL: "Books/\(UUID())/retry.epub")
        let managedURL = root.appendingPathComponent(book.fileURL)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let version = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: 0, bookID: book.id, attemptID: UUID())
        let oldJob = PendingBookMaterialization(
            token: token, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: version, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/old/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let books = SwiftDataBookStore(dbStore: db)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: 0)
        guard try await persistence.reserveRegistration(book: book, job: oldJob).disposition == .registered else {
            throw RetryRaceFixtureError.setupFailed
        }
        try await books.upsert(book)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: 0, contentRevision: revision, tombstoned: false)
        guard try await persistence.transition(token: token, from: .registered, to: .copying),
              try await persistence.transition(token: token, from: .copying, to: .paused) else {
            throw RetryRaceFixtureError.setupFailed
        }

        let generation = RetryRaceGeneration(0)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { await generation.get() },
            currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { await generation.get() })
        let oldAttemptAdmission = holdOldAttempt ? lifecycle.admitBookMaterialization(token) : nil
        guard !holdOldAttempt || oldAttemptAdmission != nil else { throw RetryRaceFixtureError.setupFailed }
        var oldPromotionGate: RetryRaceGate?
        var oldPromotionCompletion: RetryRaceCompletion?
        var oldPromotionTask: Task<Void, Never>?
        if holdOldAttempt {
            let gate = RetryRaceGate()
            let completion = RetryRaceCompletion()
            let task = Task {
                await completion.markStarted()
                do {
                    try await lifecycle.withPromotionPermit(token: token) {
                        try await gate.holdAtProof()
                    }
                } catch { }
                await completion.markComplete()
            }
            #expect(await completion.waitUntilStarted())
            _ = try #require(await gate.waitUntilEntered())
            oldPromotionGate = gate
            oldPromotionCompletion = completion
            oldPromotionTask = task
        }

        _ = lifecycle.fenceAccount(ownerID: ownerID, generation: 0)
        if !holdOldAttempt {
            await lifecycle.drainAccount(ownerID, generation: 0)
        }
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: 1)
        await generation.set(1)
        #expect(lifecycle.activateAccount(ownerID: ownerID, generation: 1))
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence,
            bookStore: books, currentGeneration: { await generation.get() }
        )
        return RetryRaceFixture(
            rootURL: root, sourceURL: sourceURL, managedURL: managedURL, bytes: bytes, digest: digest,
            ownerID: ownerID, canonicalRevision: revision, book: book, oldToken: token,
            persistence: persistence, books: books, generation: generation, registry: registry,
            lifecycle: lifecycle, coordinator: coordinator,
            accountPermit: AccountMutationPermit(ownerID: ownerID, accountGeneration: 1),
            oldAttemptAdmission: oldAttemptAdmission, oldPromotionGate: oldPromotionGate,
            oldPromotionCompletion: oldPromotionCompletion, oldPromotionTask: oldPromotionTask,
            dbStore: db
        )
    }

    func makeCoordinator(
        reprobe: @escaping @Sendable (URL, UUID) async throws -> (sha256: String, byteCount: Int64, version: ManagedFileVersion),
        scopeProbe: RetryRaceScopeProbe? = nil
    ) -> BookMaterializationCoordinator {
        BookMaterializationCoordinator(
            rootURL: rootURL, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence,
            bookStore: books, currentGeneration: { await generation.get() }, reprobeSelectedSource: reprobe,
            startSelectedSourceScope: { _ in scopeProbe?.start() ?? true },
            stopSelectedSourceScope: { _ in scopeProbe?.stop() }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeSelectedStage(named name: String, bytes: Data) throws -> URL {
        let url = rootURL.appendingPathComponent("Imports/\(name)/content.partial")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func pendingSource(for url: URL, name: String) throws -> PendingBookMaterialization {
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: 1, bookID: book.id, attemptID: UUID())
        return PendingBookMaterialization(
            token: token, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: version, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/\(name)/copy.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
    }
}

private enum RetryRaceFixtureError: Error {
    case setupFailed
}

private enum RetryProofInvalidation: String, CaseIterable, Sendable, Equatable {
    case tombstone
    case revoked
    case accountGenerationChanged
    case bookRetired
}

private actor RetryRaceGeneration {
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func get() -> UInt64 { value }
    func set(_ value: UInt64) { self.value = value }
}

private actor RetryRaceCompletion {
    private var started = false
    private var complete = false
    func markStarted() { started = true }
    func markComplete() { complete = true }
    func waitUntilStarted() async -> Bool {
        for _ in 0..<800 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }
    func waitUntilComplete() async -> Bool {
        for _ in 0..<400 {
            if complete { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return complete
    }
    func isComplete() -> Bool { complete }
}

private final class RetryRaceScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = 0

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active > 0
    }

    var counts: (starts: Int, stops: Int, active: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops, active)
    }

    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        starts += 1
        active += 1
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stops += 1
        active -= 1
    }
}

private actor RetryRaceGate {
    private var entered = false
    private var released = false

    func holdAtProof() async throws {
        entered = true
        for _ in 0..<800 {
            try Task.checkCancellation()
            if released { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RetryRaceGateError.timedOut
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<800 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
    }
}

private enum RetryRaceGateError: Error {
    case timedOut
}

private final class RetryRaceResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ outcome: Result<Value, Error>) -> Bool {
        lock.lock()
        guard case .none = self.outcome else { lock.unlock(); return false }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: outcome)
        return true
    }
}

private func boundedValue<Value: Sendable>(
    _ task: Task<Value, Error>,
    gate: RetryRaceGate? = nil,
    timeout: Duration = .seconds(4)
) async throws -> Value {
    let result = RetryRaceResult<Value>()
    Task {
        do { _ = result.resolve(.success(try await task.value)) }
        catch { _ = result.resolve(.failure(error)) }
    }
    Task {
        try? await Task.sleep(for: timeout)
        if result.resolve(.failure(RetryRaceGateError.timedOut)) {
            task.cancel()
            await gate?.release()
        }
    }
    return try await result.value()
}

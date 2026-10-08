import Foundation
import Testing
@testable import rishi

private actor DrainProbe {
    private(set) var didDrain = false
    func markDrained() { didDrain = true }
}

private actor AsyncTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if opened { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor CompletionProbe {
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func mark() {
        completed = true
        waiter?.resume()
        waiter = nil
    }
    func isCompleted() -> Bool { completed }
    func wait() async {
        if completed { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class RegistryScopeCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private var stopWaiters: [ScopeStopWaiter] = []

    var counts: (starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (startCount, stopCount)
    }

    func didStart() { lock.lock(); startCount += 1; lock.unlock() }
    func didStop() {
        lock.lock()
        stopCount += 1
        let completed = stopWaiters.filter { stopCount >= $0.expected }
        stopWaiters.removeAll { stopCount >= $0.expected }
        lock.unlock()
        completed.forEach { $0.complete(.success(())) }
    }

    func waitForStops(_ expected: Int, timeout: Duration = .seconds(5)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitUntilStopped(expected) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ScopeStopWaitError.timedOut
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func waitUntilStopped(_ expected: Int) async throws {
        let waiter = ScopeStopWaiter(expected: expected)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                lock.lock()
                let alreadyStopped = stopCount >= expected
                if !alreadyStopped { stopWaiters.append(waiter) }
                lock.unlock()
                if alreadyStopped { waiter.complete(.success(())) }
            }
        } onCancel: {
            self.remove(waiter)
            waiter.complete(.failure(CancellationError()))
        }
    }

    private func remove(_ waiter: ScopeStopWaiter) {
        lock.lock()
        stopWaiters.removeAll { $0 === waiter }
        lock.unlock()
    }
}

private enum ScopeStopWaitError: Error {
    case timedOut
}

private final class ScopeStopWaiter: @unchecked Sendable {
    let expected: Int
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(expected: Int) { self.expected = expected }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class WeakBookSourceRegistryBox {
    weak var value: BookSourceRegistry?
    init(_ value: BookSourceRegistry?) { self.value = value }
}

private actor SourceCompletionProbe {
    private var completed = false
    func mark() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor RegistryCancellationGate {
    private var entered = false
    private var released = false

    func holdCaller() async {
        entered = true
        for _ in 0..<400 {
            if released { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() { released = true }
}

private final class RecoveryFailureCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let commitEntered = DispatchSemaphore(value: 0)
    private let finishCommit = DispatchSemaphore(value: 0)
    private var order = 0
    private var commitOrder = 0
    private var advanceOrder = 0
    private var advanceAttempted = false

    func holdCommit() -> Bool {
        commitEntered.signal()
        finishCommit.wait()
        lock.lock(); order += 1; commitOrder = order; lock.unlock()
        return true
    }
    func waitForCommit() { commitEntered.wait() }
    func releaseCommit() { finishCommit.signal() }
    func markAdvanceAttempted() { lock.lock(); advanceAttempted = true; lock.unlock() }
    func didAttemptAdvance() -> Bool { lock.lock(); defer { lock.unlock() }; return advanceAttempted }
    func markAdvanced() { lock.lock(); order += 1; advanceOrder = order; lock.unlock() }
    func commitFinishedBeforeAdvance() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return commitOrder > 0 && advanceOrder > commitOrder
    }
}

private actor ManagedFingerprintBackfillProbe {
    private(set) var callCount = 0
    func recordCall() { callCount += 1 }
}

private final class ScopeReleaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0
    func release() { lock.lock(); releases += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return releases }
}

private final class MutableGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64
    init(_ generation: UInt64) { stored = generation }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ generation: UInt64) { lock.lock(); stored = generation; lock.unlock() }
}

private actor SourceTestPersistence: BookReadingSourcePersistence {
    private var storedFingerprint: BookFileFingerprint?
    private let fingerprintGate: AsyncTestGate?
    private let managedPermitGate: AsyncTestGate?
    private let gateFingerprintOnCall: Int?
    private let captureFingerprintBeforeGate: Bool
    private let allowsManagedReauthorization: Bool
    private var fingerprintCalls = 0

    init(fingerprint: BookFileFingerprint?, fingerprintGate: AsyncTestGate? = nil, gateFingerprintOnCall: Int? = nil, managedPermitGate: AsyncTestGate? = nil, captureFingerprintBeforeGate: Bool = false, allowsManagedReauthorization: Bool = true) {
        storedFingerprint = fingerprint
        self.fingerprintGate = fingerprintGate
        self.gateFingerprintOnCall = gateFingerprintOnCall
        self.managedPermitGate = managedPermitGate
        self.captureFingerprintBeforeGate = captureFingerprintBeforeGate
        self.allowsManagedReauthorization = allowsManagedReauthorization
    }

    func replaceFingerprint(_ fingerprint: BookFileFingerprint) { storedFingerprint = fingerprint }

    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? { nil }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        fingerprintCalls += 1
        let shouldGate = fingerprintCalls == gateFingerprintOnCall
        let captured = shouldGate && captureFingerprintBeforeGate ? storedFingerprint : nil
        if shouldGate { await fingerprintGate?.wait() }
        let fingerprint = shouldGate && captureFingerprintBeforeGate ? captured : storedFingerprint
        guard fingerprint?.bookID == bookID, fingerprint?.ownerID == ownerID else { return nil }
        return fingerprint
    }
    func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit? {
        guard let fingerprint = storedFingerprint,
              fingerprint.bookID == bookID, fingerprint.ownerID == ownerID else { return nil }
        return BookReadingPermit(ownerID: ownerID, accountGeneration: generation, bookID: bookID, contentRevision: fingerprint.version.materializationRevision)
    }
    func readingPermit(forManagedFingerprint expected: BookFileFingerprint, expectedRelativePath: String, generation: UInt64) async throws -> BookReadingPermit? {
        await managedPermitGate?.wait()
        guard let fingerprint = storedFingerprint,
              expectedRelativePath.hasPrefix("Books/"),
              fingerprint.bookID == expected.bookID,
              fingerprint.ownerID == expected.ownerID,
              fingerprint.sha256.caseInsensitiveCompare(expected.sha256) == .orderedSame,
              fingerprint.version == expected.version else { return nil }
        return BookReadingPermit(ownerID: expected.ownerID, accountGeneration: generation, bookID: expected.bookID, contentRevision: fingerprint.version.materializationRevision)
    }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool { throw TestError.unused }
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { throw TestError.unused }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { allowsManagedReauthorization }

    enum TestError: Error { case unused }
}

@Suite("Book source leases")
struct BookSourceRegistryTests {
    @Test("an admitted source effect drains before revocation completes")
    func admittedEffectDrains() async throws {
        let authority = BookSourceEffectAuthority()
        let permit = BookSourceAccessPermit()
        authority.register(permit)
        let admission = try authority.admit(permit)
        authority.closeAdmission(permit)
        #expect(throws: BookSourceAccessError.revoked) { try authority.admit(permit) }

        let probe = DrainProbe()
        let drained = Task {
            await authority.drain(permit)
            await probe.markDrained()
        }
        await Task.yield()
        #expect(await !probe.didDrain)
        admission.release()
        await drained.value
        admission.release() // idempotent
    }

    @Test("replacing the future source leaves an existing lease URL and owner intact")
    func replacementKeepsExistingLease() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Lease", formatType: .pdf, fileURL: "Books/book.pdf")
        let registry = BookSourceRegistry(currentGeneration: { 7 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let firstURL = URL(fileURLWithPath: "/tmp/source-one.pdf")
        let secondURL = URL(fileURLWithPath: "/tmp/source-two.pdf")
        try await registry.registerSource(for: book, url: firstURL, accountGeneration: 7, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 7, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        let oldLease = try await registry.acquireReadableSource(for: book)
        let oldOwner = oldLease.owner

        try await registry.registerSource(for: book, url: secondURL, accountGeneration: 7, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 7, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        let newLease = try await registry.acquireReadableSource(for: book)

        #expect(oldLease.url == firstURL)
        #expect(oldLease.owner === oldOwner)
        #expect(newLease.url == secondURL)
        #expect(newLease.owner !== oldOwner)
    }

    @Test("reader release keeps the shared source scope until the audio lease releases")
    func sharedLeaseOwnsScopeUntilLastConsumer() async throws {
        let probe = ScopeReleaseProbe()
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        var owner: BookSourceOwner? = try BookSourceOwner(
            url: URL(fileURLWithPath: "/tmp/source.pdf"),
            access: .localPreview,
            sourceAccessPermit: permit,
            effectAuthority: authority,
            stopAccessing: { probe.release() }
        )
        let lifetime = owner!.lifetime
        var readerLease: BookSourceLease? = BookSourceLease(owner: owner!, cachePolicy: .transient)
        var audioLease: BookSourceLease? = BookSourceLease(owner: owner!, cachePolicy: .transient)
        #expect(readerLease?.owner === audioLease?.owner)

        owner = nil
        readerLease = nil
        #expect(probe.count == 0)
        audioLease = nil
        await lifetime.waitForRelease()
        #expect(probe.count == 1)
    }

    @Test("account fence closes source admission synchronously and drains afterward")
    func accountFenceIsSynchronous() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Lease", formatType: .epub, fileURL: "Books/book.epub")
        let registry = BookSourceRegistry(currentGeneration: { 3 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/source.epub"), accountGeneration: 3, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 3, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        var lease: BookSourceLease? = try await registry.acquireReadableSource(for: book)
        let invalidation = try #require(lease).invalidation
        let invalidationObserved = Task {
            for await _ in invalidation { return true }
            return false
        }
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)

        lifecycle.fenceAccount(ownerID: userID, generation: 3)
        #expect(throws: BookSourceAccessError.revoked) { try lease!.effectAuthority.admit(lease!.sourceAccessPermit) }
        #expect(await invalidationObserved.value)
        lease = nil
        await lifecycle.drainAccount(userID, generation: 3)
        #expect(!lifecycle.admits(ownerID: userID, generation: 3))
    }

    @Test("book retirement invalidates its readers before waiting for their lease")
    func bookRetirementInvalidatesLeaseBeforeDrain() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Lease", formatType: .pdf, fileURL: "Books/book.pdf")
        let registry = BookSourceRegistry(currentGeneration: { 4 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/source.pdf"), accountGeneration: 4, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 4, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        var lease: BookSourceLease? = try await registry.acquireReadableSource(for: book)
        let invalidation = try #require(lease).invalidation
        let invalidationObserved = Task {
            for await _ in invalidation { return true }
            return false
        }
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)

        lifecycle.retireBook(ownerID: userID, generation: 4, bookID: book.id)
        #expect(await invalidationObserved.value)
        #expect(throws: BookSourceAccessError.revoked) { try lease!.effectAuthority.admit(lease!.sourceAccessPermit) }
        lease = nil
        await lifecycle.drainBook(ownerID: userID, generation: 4, bookID: book.id)
    }

    @Test("source registration cannot cross a completed account fence")
    func registrationAndFenceShareOneBarrier() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Race", formatType: .pdf, fileURL: "Books/race.pdf")
        let registry = BookSourceRegistry(currentGeneration: { 5 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        lifecycle.fenceAccount(ownerID: userID, generation: 5)

        await #expect(throws: BookSourceRegistryError.accountRevoked) {
            try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/race.pdf"), accountGeneration: 5, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 5, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        }
    }

    @Test("owner transition fence blocks old-owner managed lookup at the incremented generation")
    func ownerTransitionBlocksGenerationAdvanceRace() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/legacy.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = UUID()
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/legacy.pdf")
        let generation = MutableGeneration(60)
        let persistence = SourceTestPersistence(fingerprint: BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "legacy", version: version))
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation.value }, currentOwnerID: { userID }, managedURL: { _ in url })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation.value })

        lifecycle.fenceAccount(ownerID: userID, generation: 60)
        generation.set(61) // beginAccountChange increments while the old ID remains visible.
        #expect(try await registry.managedSource(for: book) == nil)
        await #expect(throws: BookSourceRegistryError.unavailable) { try await registry.acquireReadableSource(for: book) }
        await #expect(throws: BookSourceRegistryError.accountRevoked) {
            try await registry.registerSource(for: book, url: url, accountGeneration: 61, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 61, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        }

        lifecycle.activateAccount(ownerID: userID, generation: 61)
        #expect(!lifecycle.admits(ownerID: userID, generation: 60))
        #expect(lifecycle.admits(ownerID: userID, generation: 61))
        #expect(try await registry.managedSource(for: book) != nil)
        let lease = try await registry.acquireReadableSource(for: book)
        #expect(lease.url == url)
    }

    @Test("managed lookup refuses a verified file when durable reading reauthorization fails")
    func managedLookupRequiresReauthorization() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-managed-reauth-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/book.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified content".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = UUID()
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let book = Book(id: bookID, userId: userID, title: "Managed", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/book.pdf")
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "verified", version: version)
        let persistence = SourceTestPersistence(fingerprint: fingerprint, allowsManagedReauthorization: false)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { 12 },
            currentOwnerID: { userID },
            managedURL: { _ in url }
        )

        #expect(try await registry.managedSource(for: book) == nil)
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.acquireReadableSource(for: book)
        }
    }

    @Test("a stale presenter callback cannot remove a replacement source")
    func stalePresenterCannotRevokeReplacement() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Swap", formatType: .pdf, fileURL: "Books/swap.pdf")
        let registry = BookSourceRegistry(currentGeneration: { 8 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let oldPermit = try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/old.pdf"), accountGeneration: 8, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 8, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/new.pdf"), accountGeneration: 8, readingPermit: BookReadingPermit(ownerID: book.userId, accountGeneration: 8, bookID: book.id, contentRevision: UUID()), requiresSecurityScope: false, observeChanges: false)

        await registry.presenterInvalidated(bookID: book.id, permit: oldPermit, token: nil, changedURL: nil)
        let current = try await registry.acquireReadableSource(for: book)
        #expect(current.url == URL(fileURLWithPath: "/tmp/new.pdf"))
        let admission = try current.effectAuthority.admit(current.sourceAccessPermit)
        admission.release()
    }

    @Test("a managed ready lease is registered with the account fence")
    func managedLeaseIsAccountFenced() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/book.pdf"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("managed bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = UUID()
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let book = Book(id: bookID, userId: userID, title: "Managed", formatType: .pdf, fileURL: relativePath)
        let persistence = SourceTestPersistence(fingerprint: BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "digest", version: version))
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { 4 }, currentOwnerID: { userID }, managedURL: { _ in url })
        var lease: BookSourceLease? = try await registry.acquireReadableSource(for: book)
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)

        lifecycle.fenceAccount(ownerID: userID, generation: 4)
        #expect(throws: BookSourceAccessError.revoked) { try lease!.effectAuthority.admit(lease!.sourceAccessPermit) }
        lease = nil
        await lifecycle.drainAccount(userID, generation: 4)
    }

    @Test("legacy managed books without a materialization job require matching fingerprint stat")
    func noJobManagedSourceNeedsCurrentStat() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/book.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("valid epub".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = UUID()
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        let registry = BookSourceRegistry(
            persistence: SourceTestPersistence(fingerprint: BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "cached", version: version)),
            currentGeneration: { 11 },
            currentOwnerID: { userID },
            managedURL: { _ in url }
        )
        #expect(try await registry.managedSource(for: book) != nil)

        try Data("changed bytes and length".utf8).write(to: url)
        #expect(try await registry.managedSource(for: book) == nil)
    }

    @Test("a verified backfill makes a legacy managed book readable when its fingerprint is missing")
    func missingLegacyFingerprintIsBackfilledBeforeAcquiringSource() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/legacy.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy managed EPUB".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "verified-legacy-digest", version: version)
        let persistence = SourceTestPersistence(fingerprint: nil)
        let backfill = ManagedFingerprintBackfillProbe()
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { 31 },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { candidate in
                guard candidate.id == book.id, candidate.userId == userID else { return false }
                await backfill.recordCall()
                await persistence.replaceFingerprint(fingerprint)
                return true
            },
            managedURL: { _ in url }
        )

        let lease = try await registry.acquireReadableSource(for: book)

        #expect(lease.url == url)
        #expect(await backfill.callCount == 1)
        #expect(lease.access == .account(BookReadingPermit(
            ownerID: userID,
            accountGeneration: 31,
            bookID: bookID,
            contentRevision: version.materializationRevision
        )))
    }

    @Test("managed books with a fingerprint do not invoke legacy backfill")
    func existingManagedFingerprintSkipsBackfill() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/book.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already fingerprinted EPUB".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let book = Book(id: bookID, userId: userID, title: "Known", formatType: .epub, fileURL: relativePath)
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "cached-digest", version: version)
        let backfill = ManagedFingerprintBackfillProbe()
        let registry = BookSourceRegistry(
            persistence: SourceTestPersistence(fingerprint: fingerprint),
            currentGeneration: { 32 },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { _ in
                await backfill.recordCall()
                return false
            },
            managedURL: { _ in url }
        )

        #expect(try await registry.managedSource(for: book) != nil)
        #expect(await backfill.callCount == 0)
    }

    @Test("a failed legacy fingerprint backfill keeps the managed source unavailable")
    func failedLegacyFingerprintBackfillIsRejected() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/legacy.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy managed EPUB".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        let persistence = SourceTestPersistence(fingerprint: nil)
        let backfill = ManagedFingerprintBackfillProbe()
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { 33 },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { candidate in
                guard candidate.id == book.id else { return false }
                await backfill.recordCall()
                return false
            },
            managedURL: { _ in url }
        )

        #expect(try await registry.managedSource(for: book) == nil)
        #expect(await backfill.callCount == 1)
        #expect(try await persistence.fingerprint(bookID: bookID, ownerID: userID) == nil)
    }

    @Test("a generation change during legacy fingerprint backfill rejects the stale acquisition")
    func generationChangeDuringLegacyFingerprintBackfillIsRejected() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/legacy.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy managed EPUB".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let generation = MutableGeneration(34)
        let gate = AsyncTestGate()
        let backfill = ManagedFingerprintBackfillProbe()
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "verified-legacy-digest", version: version)
        let persistence = SourceTestPersistence(fingerprint: nil)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation.value },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { candidate in
                guard candidate.id == book.id else { return false }
                await backfill.recordCall()
                await gate.wait()
                await persistence.replaceFingerprint(fingerprint)
                return true
            },
            managedURL: { _ in url }
        )

        let acquisition = Task { try await registry.acquireReadableSource(for: book) }
        await gate.waitUntilEntered()
        generation.set(35)
        await gate.open()

        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await acquisition.value
        }
        #expect(await backfill.callCount == 1)
    }

    @Test("concurrent stale-nil acquisitions avoid duplicate legacy verification")
    func concurrentStaleNilAcquisitionsAvoidDuplicateVerification() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let relativePath = "Books/\(bookID.uuidString)/legacy.epub"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shared legacy managed EPUB".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }

        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "verified-shared-digest", version: version)
        let backfillGate = AsyncTestGate()
        let secondLookupGate = AsyncTestGate()
        let backfill = ManagedFingerprintBackfillProbe()
        // The first fingerprint read is the caller lookup and the second is
        // the verifier's recheck. Hold the third read to prove the second
        // acquisition has reached persistence lookup while verification is
        // still blocked.
        let persistence = SourceTestPersistence(
            fingerprint: nil,
            fingerprintGate: secondLookupGate,
            gateFingerprintOnCall: 3,
            captureFingerprintBeforeGate: true
        )
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { 36 },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { candidate in
                guard candidate.id == book.id else { return false }
                await backfill.recordCall()
                await backfillGate.wait()
                await persistence.replaceFingerprint(fingerprint)
                return true
            },
            managedURL: { _ in url }
        )

        let first = Task { try await registry.acquireReadableSource(for: book) }
        await backfillGate.waitUntilEntered()
        let second = Task { try await registry.acquireReadableSource(for: book) }
        await secondLookupGate.waitUntilEntered()
        #expect(await backfill.callCount == 1)
        await secondLookupGate.open()
        await backfillGate.open()

        let firstLease = try await first.value
        let secondLease = try await second.value
        #expect(firstLease.url == url)
        #expect(secondLease.url == url)
        #expect(firstLease.owner.access == .account(BookReadingPermit(
            ownerID: userID,
            accountGeneration: 36,
            bookID: bookID,
            contentRevision: version.materializationRevision
        )))
        #expect(secondLease.owner.access == firstLease.owner.access)
        #expect(await backfill.callCount == 1)
    }

    @Test("a ready notification wakes a registered waiter which validates persisted provenance")
    func readyEventRaceIsClosed() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/race.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first version".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: bookID, userId: userID, title: "Race", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/race.pdf")
        let revision = UUID()
        let firstVersion = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let gate = AsyncTestGate()
        let persistence = SourceTestPersistence(fingerprint: nil, fingerprintGate: gate, gateFingerprintOnCall: 2)
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { 13 }, currentOwnerID: { userID }, managedURL: { _ in url })
        let waiter = Task { try await registry.awaitManagedSource(for: book) }
        await gate.waitUntilEntered() // The waiter has been registered before its recheck.
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "first", version: firstVersion)
        await persistence.replaceFingerprint(fingerprint)
        let readySource = ManagedBookSource(bookID: bookID, url: url, fingerprint: fingerprint, readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 13, bookID: bookID, contentRevision: revision))
        await registry.managedSourceBecameReady(readySource)
        await gate.open()
        #expect(try await waiter.value == readySource)
    }

    @Test("a ready notification cannot return a source after the managed file changes")
    func readyNotificationRechecksChangedFile() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/race.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: bookID, userId: userID, title: "Race", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/race.pdf")
        let revision = UUID()
        let oldVersion = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let persistence = SourceTestPersistence(fingerprint: BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "old", version: oldVersion))
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { 14 }, currentOwnerID: { userID }, managedURL: { _ in url })
        let staleSource = ManagedBookSource(bookID: bookID, url: url, fingerprint: try #require(await persistence.fingerprint(bookID: bookID, ownerID: userID)), readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 14, bookID: bookID, contentRevision: revision))
        try Data("after with different size".utf8).write(to: url)

        let completed = SourceCompletionProbe()
        let waiter = Task {
            let source = try await registry.awaitManagedSource(for: book)
            await completed.mark()
            return source
        }
        await registry.managedSourceBecameReady(staleSource)
        await Task.yield()
        await Task.yield()
        #expect(await !completed.isCompleted())

        let currentVersion = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let currentFingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "new", version: currentVersion)
        await persistence.replaceFingerprint(currentFingerprint)
        await registry.managedSourceBecameReady(ManagedBookSource(bookID: bookID, url: url, fingerprint: currentFingerprint, readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 14, bookID: bookID, contentRevision: revision)))
        let resolved = try await waiter.value
        #expect(resolved.fingerprint == currentFingerprint)
    }

    @Test("managed fingerprint replacement between lookup and permit resolution fails closed")
    func managedFingerprintAndPermitAreResolvedAsOneSnapshot() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/race.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fingerprint A".utf8).write(to: url)
        let book = Book(id: bookID, userId: userID, title: "Race", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/race.pdf")
        let oldVersion = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let oldFingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "digest-a", version: oldVersion)
        let gate = AsyncTestGate()
        let persistence = SourceTestPersistence(fingerprint: oldFingerprint, managedPermitGate: gate)
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { 21 }, currentOwnerID: { userID }, managedURL: { _ in url })

        let pendingResolution = Task { try await registry.managedSource(for: book) }
        await gate.waitUntilEntered()
        try Data("different verified fingerprint B".utf8).write(to: url)
        let newVersion = try #require(try CoordinatedSourceProbe.version(at: url, revision: UUID()))
        let newFingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "digest-b", version: newVersion)
        await persistence.replaceFingerprint(newFingerprint)
        await gate.open()

        #expect(try await pendingResolution.value == nil)
        let currentSource = try #require(try await registry.managedSource(for: book))
        #expect(currentSource.fingerprint == newFingerprint)
        #expect(currentSource.readingPermit.contentRevision == newFingerprint.version.materializationRevision)
    }

    @Test("book retirement synchronously rejects previously ready managed sources")
    func readySourceCannotCrossBookRetirement() async throws {
        let userID = UUID()
        let bookID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("Books/\(bookID.uuidString)/retired.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retired".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = Book(id: bookID, userId: userID, title: "Retired", formatType: .pdf, fileURL: "Books/\(bookID.uuidString)/retired.pdf")
        let revision = UUID()
        let version = try #require(try CoordinatedSourceProbe.version(at: url, revision: revision))
        let fingerprint = BookFileFingerprint(bookID: bookID, ownerID: userID, sha256: "valid", version: version)
        let registry = BookSourceRegistry(persistence: SourceTestPersistence(fingerprint: fingerprint), currentGeneration: { 15 }, currentOwnerID: { userID }, managedURL: { _ in url })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        await registry.managedSourceBecameReady(ManagedBookSource(bookID: bookID, url: url, fingerprint: fingerprint, readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 15, bookID: bookID, contentRevision: revision)))

        lifecycle.retireBook(ownerID: userID, generation: 15, bookID: bookID)
        #expect(try await registry.managedSource(for: book) == nil)
        await #expect(throws: BookSourceRegistryError.accountRevoked) { try await registry.awaitManagedSource(for: book) }
    }

    @Test("a terminal failure between lookup and waiter registration is retained")
    func failureEventRaceIsClosed() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Failure race", formatType: .epub, fileURL: "Books/failure.epub")
        let gate = AsyncTestGate()
        let persistence = SourceTestPersistence(fingerprint: nil, fingerprintGate: gate, gateFingerprintOnCall: 1)
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { 16 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let waiter = Task { try await registry.awaitManagedSource(for: book) }

        await gate.waitUntilEntered()
        await registry.failPendingSource(ownerID: userID, generation: 16, bookID: book.id)
        await gate.open()
        await #expect(throws: BookSourceRegistryError.unavailable) { try await waiter.value }
    }

    @Test("recovery failure permit cannot complete a waiter after a newer attempt advances")
    func staleRecoveryFailurePermitDoesNotFailNewEpochWaiter() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Epoch", formatType: .epub, fileURL: "Books/epoch.epub")
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: 9, bookID: book.id))
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let stalePermit = BookImportRecoverySourceFailurePermit(ownerID: owner, generation: 9, bookID: book.id, token: oldToken, attemptEpoch: 1)
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: 9, bookID: book.id))

        let waiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) {
            await Task.yield()
        }
        #expect(!(await registry.failRecoveryWaiters(for: book, permit: stalePermit)))
        #expect(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test("recovery failure permit wakes waiters admitted before its epoch")
    func recoveryFailurePermitWakesEarlierEpochWaiters() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Epoch", formatType: .epub, fileURL: "Books/epoch.epub")
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: 9, bookID: book.id))
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let waiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) {
            await Task.yield()
        }
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: 9, bookID: book.id))
        let permit = BookImportRecoverySourceFailurePermit(ownerID: owner, generation: 9, bookID: book.id, token: oldToken, attemptEpoch: 2)
        #expect(await registry.failRecoveryWaiters(for: book, permit: permit))
        await #expect(throws: BookSourceRegistryError.unavailable) { try await waiter.value }
    }

    @Test("synchronous attempt advance linearizes after an in-flight recovery failure commit")
    func recoveryFailureCommitIsAtomicAgainstAttemptAdvance() async throws {
        let owner = UUID()
        let bookID = UUID()
        let fence = BookSourceRegistryFence()
        #expect(fence.activateBook(ownerID: owner, generation: 9, bookID: bookID))
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: bookID, attemptID: UUID())
        let permit = BookImportRecoverySourceFailurePermit(ownerID: owner, generation: 9, bookID: bookID, token: token, attemptEpoch: 1)
        let gate = RecoveryFailureCommitGate()
        let commit = Task.detached(priority: .userInitiated) {
            fence.commitRecoveryFailureIfCurrent(permit) { gate.holdCommit() }
        }
        gate.waitForCommit()
        let advance = Task.detached(priority: .userInitiated) {
            gate.markAdvanceAttempted()
            let advanced = fence.activateBook(ownerID: owner, generation: 9, bookID: bookID)
            gate.markAdvanced()
            return advanced
        }
        while !gate.didAttemptAdvance() { await Task.yield() }
        #expect(!gate.commitFinishedBeforeAdvance())
        gate.releaseCommit()
        #expect(await commit.value)
        #expect(await advance.value)
        #expect(gate.commitFinishedBeforeAdvance())
        #expect(fence.bookAttemptEpoch(ownerID: owner, generation: 9, bookID: bookID) == 2)
    }

    @Test("a source that cannot start security-scoped access is rejected")
    func securityScopeFailureDoesNotCreateOwner() throws {
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        #expect(throws: BookSourceOwnerError.securityScopeUnavailable) {
            try BookSourceOwner(url: URL(fileURLWithPath: "/tmp/no-access.pdf"), access: .localPreview, sourceAccessPermit: permit, effectAuthority: authority, usesSecurityScope: true, startAccessing: { _ in false })
        }
    }

    @Test("retry cannot reopen a permanent book retirement fence")
    func retryAttemptCannotReopenRetiredBook() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Retry", formatType: .epub, fileURL: "Books/retry.epub")
        let registry = BookSourceRegistry(currentGeneration: { 29 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        lifecycle.retireBook(ownerID: userID, generation: 29, bookID: book.id)
        await lifecycle.drainBook(ownerID: userID, generation: 29, bookID: book.id)

        let token = BookMaterializationToken(ownerID: userID, accountGeneration: 29, bookID: book.id, attemptID: UUID())
        #expect(!lifecycle.activatePromotionAttempt(token))
        await #expect(throws: BookSourceRegistryError.accountRevoked) {
            try await registry.registerSource(
                for: book,
                url: URL(fileURLWithPath: "/tmp/retried.epub"),
                accountGeneration: 29,
                readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 29, bookID: book.id, contentRevision: UUID()),
                token: token,
                requiresSecurityScope: false,
                observeChanges: false
            )
        }
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.acquireReadableSource(for: book)
        }
    }

    @Test("registry scope adapters balance scoped owners without retaining the registry")
    func sourceScopeAdapterBalancesAndDoesNotRetainRegistry() async throws {
        for requiresScope in [false, true] {
            let userID = UUID()
            let book = Book(userId: userID, title: "Scope", formatType: .epub, fileURL: "Books/scope.epub")
            let scopeCounts = RegistryScopeCounts()
            var registry: BookSourceRegistry? = BookSourceRegistry(
                currentGeneration: { 73 },
                currentOwnerID: { userID },
                startSecurityScope: { _ in scopeCounts.didStart(); return true },
                stopSecurityScope: { _ in scopeCounts.didStop() },
                managedURL: { _ in nil }
            )
            let weakRegistry = WeakBookSourceRegistryBox(registry)
            try await registry?.registerSource(
                for: book,
                url: URL(fileURLWithPath: "/tmp/scope-source.epub"),
                accountGeneration: 73,
                readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 73, bookID: book.id, contentRevision: UUID()),
                requiresSecurityScope: requiresScope,
                observeChanges: false
            )
            #expect(scopeCounts.counts.starts == (requiresScope ? 1 : 0))
            await registry?.retire(ownerID: userID, generation: 73)
            await registry?.drain(ownerID: userID, generation: 73)
            #expect(scopeCounts.counts.stops == (requiresScope ? 1 : 0))
            registry = nil
            #expect(weakRegistry.value == nil)
        }
    }

    @Test("dropping a registry with a live scoped entry releases its owner without retirement")
    func liveScopedEntryDoesNotRetainRegistry() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Live Scope", formatType: .epub, fileURL: "Books/live-scope.epub")
        let scopeCounts = RegistryScopeCounts()
        var weakRegistry: WeakBookSourceRegistryBox!
        do {
            var registry: BookSourceRegistry? = BookSourceRegistry(
                currentGeneration: { 74 },
                currentOwnerID: { userID },
                startSecurityScope: { _ in scopeCounts.didStart(); return true },
                stopSecurityScope: { _ in scopeCounts.didStop() },
                managedURL: { _ in nil }
            )
            weakRegistry = WeakBookSourceRegistryBox(registry)
            try await registry?.registerSource(
                for: book,
                url: URL(fileURLWithPath: "/tmp/live-scope-source.epub"),
                accountGeneration: 74,
                readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 74, bookID: book.id, contentRevision: UUID()),
                requiresSecurityScope: true,
                observeChanges: false
            )
            #expect(scopeCounts.counts == (starts: 1, stops: 0))
            registry = nil
        }

        #expect(weakRegistry.value == nil)
        try await scopeCounts.waitForStops(1)
        #expect(scopeCounts.counts == (starts: 1, stops: 1))
    }

    @Test("scope release wait reports timeout and safely responds to cancellation")
    func scopeReleaseWaitIsBoundedAndCancellable() async throws {
        let scopeCounts = RegistryScopeCounts()
        await #expect(throws: ScopeStopWaitError.timedOut) {
            try await scopeCounts.waitForStops(1, timeout: .milliseconds(1))
        }

        let cancelledWait = Task { try await scopeCounts.waitForStops(1) }
        cancelledWait.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledWait.value }

        scopeCounts.didStop()
        try await scopeCounts.waitForStops(1)
    }

    @Test("owned-source cleanup atomically blocks new transient leases and waits for existing leases")
    func ownedSourceCleanupRetiresTransientEntry() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Owned", formatType: .epub, fileURL: "Books/owned.epub")
        let token = BookMaterializationToken(ownerID: userID, accountGeneration: 41, bookID: book.id, attemptID: UUID())
        let registry = BookSourceRegistry(currentGeneration: { 41 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        try await registry.registerSource(
            for: book,
            url: URL(fileURLWithPath: "/tmp/owned-source.epub"),
            accountGeneration: 41,
            readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 41, bookID: book.id, contentRevision: UUID()),
            token: token,
            requiresSecurityScope: false,
            observeChanges: false
        )
        var lease: BookSourceLease? = try await registry.acquireReadableSource(for: book)

        let blockedWhileLeased = await registry.prepareOwnedSourceCleanup(for: token)
        #expect(!blockedWhileLeased)
        lease = nil
        var cleanupReady = false
        for _ in 0..<10_000 {
            if await registry.prepareOwnedSourceCleanup(for: token) {
                cleanupReady = true
                break
            }
            await Task.yield()
        }
        #expect(cleanupReady)
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.acquireReadableSource(for: book)
        }
    }

    @Test("cancelled transient publication is rejected at registry actor ingress")
    func cancelledTransientPublicationRemainsUnavailable() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Cancelled transient", formatType: .epub, fileURL: "Books/cancelled-transient.epub")
        let token = BookMaterializationToken(ownerID: userID, accountGeneration: 42, bookID: book.id, attemptID: UUID())
        let registry = BookSourceRegistry(currentGeneration: { 42 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let accessPermit = try await registry.registerSource(
            for: book,
            url: URL(fileURLWithPath: "/tmp/cancelled-transient.epub"),
            accountGeneration: 42,
            readingPermit: BookReadingPermit(ownerID: userID, accountGeneration: 42, bookID: book.id, contentRevision: UUID()),
            token: token,
            requiresSecurityScope: false,
            observeChanges: false,
            published: false
        )
        let gate = RegistryCancellationGate()
        let dispatch = Task<Bool, Error> {
            await gate.holdCaller()
            return await registry.publishTransientSource(
                ownerID: userID, generation: 42, bookID: book.id, token: token, permit: accessPermit
            )
        }

        _ = try #require(await gate.waitUntilEntered())
        dispatch.cancel()
        await gate.release()
        #expect(try await dispatch.value == false)
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.acquireReadableSource(for: book)
        }
    }

    @Test("provider deletion callback waits for admitted source effects to drain")
    func providerDeletionWaitsForDrain() async throws {
        let gate = AsyncTestGate()
        let completion = CompletionProbe()
        let presenter = BookSourcePresenter(
            url: URL(fileURLWithPath: "/tmp/presented.pdf"),
            onInvalidated: { _ in },
            drainBeforeYield: { await gate.wait() }
        )
        presenter.accommodatePresentedItemDeletion { _ in Task { await completion.mark() } }
        await Task.yield()
        #expect(await !completion.isCompleted())
        await gate.open()
        await completion.wait()
        #expect(await completion.isCompleted())
        presenter.invalidateAndStop()
    }

    @Test("artwork admission uses owner generation and synchronous retirement fences")
    func artworkAdmissionFailsClosedAtRegistryFences() async {
        let owner = UUID()
        let generation = MutableGeneration(73)
        let book = Book(userId: owner, title: "Artwork", formatType: .epub, fileURL: "Books/\(UUID().uuidString)/book.epub")
        let registry = BookSourceRegistry(
            currentGeneration: { generation.value },
            currentOwnerID: { owner },
            managedURL: { _ in nil }
        )

        #expect(await registry.allowsArtworkRead(for: book, generation: 73))
        registry.fenceBookSynchronously(ownerID: owner, generation: 73, bookID: book.id)
        #expect(!(await registry.allowsArtworkRead(for: book, generation: 73)))
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: 73, bookID: book.id))
        #expect(await registry.allowsArtworkRead(for: book, generation: 73))

        generation.set(74)
        #expect(!(await registry.allowsArtworkRead(for: book, generation: 73)))
        let epoch = registry.fenceAccountSynchronously(ownerID: owner, generation: 74)
        #expect(!(await registry.allowsArtworkRead(for: book, generation: 74)))
        #expect(registry.activateAccountSynchronously(ownerID: owner, generation: 74, epoch: epoch))
        #expect(await registry.allowsArtworkRead(for: book, generation: 74))

        let foreign = Book(userId: UUID(), title: book.title, formatType: book.formatType, fileURL: book.fileURL)
        #expect(!(await registry.allowsArtworkRead(for: foreign, generation: 74)))
    }
}

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

private actor SourceCompletionProbe {
    private var completed = false
    func mark() { completed = true }
    func isCompleted() -> Bool { completed }
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

private actor SourceTestPersistence: BookImportPersistence {
    private var storedFingerprint: BookFileFingerprint?
    private let fingerprintGate: AsyncTestGate?
    private let gateFingerprintOnCall: Int?
    private let allowsManagedReauthorization: Bool
    private var fingerprintCalls = 0

    init(fingerprint: BookFileFingerprint?, fingerprintGate: AsyncTestGate? = nil, gateFingerprintOnCall: Int? = nil, allowsManagedReauthorization: Bool = true) {
        storedFingerprint = fingerprint
        self.fingerprintGate = fingerprintGate
        self.gateFingerprintOnCall = gateFingerprintOnCall
        self.allowsManagedReauthorization = allowsManagedReauthorization
    }

    func replaceFingerprint(_ fingerprint: BookFileFingerprint) { storedFingerprint = fingerprint }

    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? { nil }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        fingerprintCalls += 1
        if fingerprintCalls == gateFingerprintOnCall { await fingerprintGate?.wait() }
        guard storedFingerprint?.bookID == bookID, storedFingerprint?.ownerID == ownerID else { return nil }
        return storedFingerprint
    }
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration { throw TestError.unused }
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? { throw TestError.unused }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool { throw TestError.unused }
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool { throw TestError.unused }
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool { throw TestError.unused }
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? { throw TestError.unused }
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { throw TestError.unused }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { allowsManagedReauthorization }
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws { throw TestError.unused }
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws { throw TestError.unused }

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
        try await registry.registerSource(for: book, url: firstURL, accountGeneration: 7, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
        let oldLease = try await registry.acquireReadableSource(for: book)
        let oldOwner = oldLease.owner

        try await registry.registerSource(for: book, url: secondURL, accountGeneration: 7, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
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
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/source.epub"), accountGeneration: 3, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
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
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/source.pdf"), accountGeneration: 4, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
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
            try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/race.pdf"), accountGeneration: 5, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
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
            try await registry.registerSource(for: book, url: url, accountGeneration: 61, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
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
        let oldPermit = try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/old.pdf"), accountGeneration: 8, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)
        try await registry.registerSource(for: book, url: URL(fileURLWithPath: "/tmp/new.pdf"), accountGeneration: 8, contentRevision: UUID(), requiresSecurityScope: false, observeChanges: false)

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
        let readySource = ManagedBookSource(bookID: bookID, url: url, fingerprint: fingerprint, accountGeneration: 13)
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
        let staleSource = ManagedBookSource(bookID: bookID, url: url, fingerprint: try #require(await persistence.fingerprint(bookID: bookID, ownerID: userID)), accountGeneration: 14)
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
        await registry.managedSourceBecameReady(ManagedBookSource(bookID: bookID, url: url, fingerprint: currentFingerprint, accountGeneration: 14))
        let resolved = try await waiter.value
        #expect(resolved.fingerprint == currentFingerprint)
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
        await registry.managedSourceBecameReady(ManagedBookSource(bookID: bookID, url: url, fingerprint: fingerprint, accountGeneration: 15))

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

    @Test("a source that cannot start security-scoped access is rejected")
    func securityScopeFailureDoesNotCreateOwner() throws {
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        #expect(throws: BookSourceOwnerError.securityScopeUnavailable) {
            try BookSourceOwner(url: URL(fileURLWithPath: "/tmp/no-access.pdf"), access: .localPreview, sourceAccessPermit: permit, effectAuthority: authority, usesSecurityScope: true, startAccessing: { _ in false })
        }
    }

    @Test("a drained retry attempt reopens only its retired book admission")
    func retryAttemptReopensRetiredBook() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Retry", formatType: .epub, fileURL: "Books/retry.epub")
        let registry = BookSourceRegistry(currentGeneration: { 29 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        lifecycle.retireBook(ownerID: userID, generation: 29, bookID: book.id)
        await lifecycle.drainBook(ownerID: userID, generation: 29, bookID: book.id)

        let token = BookMaterializationToken(ownerID: userID, accountGeneration: 29, bookID: book.id, attemptID: UUID())
        #expect(lifecycle.activatePromotionAttempt(token))
        try await registry.registerSource(
            for: book,
            url: URL(fileURLWithPath: "/tmp/retried.epub"),
            accountGeneration: 29,
            contentRevision: UUID(),
            token: token,
            requiresSecurityScope: false,
            observeChanges: false
        )
        #expect(try await registry.acquireReadableSource(for: book).url == URL(fileURLWithPath: "/tmp/retried.epub"))
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
            contentRevision: UUID(),
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
}

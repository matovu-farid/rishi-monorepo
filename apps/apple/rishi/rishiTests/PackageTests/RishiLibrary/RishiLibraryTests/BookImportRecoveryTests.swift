@testable import rishi
import Foundation
import Testing

@Suite(.serialized)
struct BookImportRecoveryTests {
    @Test("a claimed recovery lookup error wakes joined readers and preserves the lookup error")
    func claimedLookupErrorWakesJoinedReader() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Lookup error", formatType: .epub, fileURL: "Books/lookup-error.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let job = recoveryJob(book: book, token: token)
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9, pendingRecoveryFailureOnCall: 2)
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]), persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry))
        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) { await Task.yield() }

        await #expect(throws: RecoveryInjectedPersistenceError.self) { try await recovery.recover(ownerID: owner, generation: 9) }
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
    }

    @Test("a claimed adoption error wakes joined readers and preserves the CAS error")
    func claimedAdoptionErrorWakesJoinedReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("Books/cas-error.staging")
        try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: stage)
        let owner = UUID()
        let book = Book(userId: owner, title: "CAS error", formatType: .epub, fileURL: "Books/cas-error.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: stage, materializationRevision: revision))
        let job = PendingBookMaterialization(token: token, sourceKind: .ownedStaging, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: version,
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Books/cas-error.staging",
            destinationRelativePath: book.fileURL, phase: .prepared, preparedFileIdentifier: version.fileIdentifier)
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9, adoptionThrows: true)
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(rootURL: root, bookStore: RecoveryBookStore([book]), persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry))
        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) { await Task.yield() }

        await #expect(throws: RecoveryInjectedPersistenceError.self) { try await recovery.recover(ownerID: owner, generation: 9) }
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
    }

    @Test("a processing error wakes waiters for every later claimed book")
    func processingErrorWakesLaterClaimedBookWaiter() async throws {
        let owner = UUID()
        let first = Book(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, userId: owner, title: "First", formatType: .pdf, fileURL: "Books/first.pdf")
        let second = Book(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, userId: owner, title: "Second", formatType: .pdf, fileURL: "Books/second.pdf")
        let firstToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: first.id, attemptID: UUID())
        let secondToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: second.id, attemptID: UUID())
        let persistence = RecoveryPersistence(
            jobs: [first.id: recoveryJob(book: first, token: firstToken), second.id: recoveryJob(book: second, token: secondToken)],
            currentGeneration: 9,
            adoptionThrows: true
        )
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(rootURL: FileManager.default.temporaryDirectory,
            bookStore: OrderedRecoveryBookStore(orderedBooks: [first, second]), persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry))
        let joinedWaiter = Task { try await registry.awaitManagedSource(for: second) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: second.id)) { await Task.yield() }

        await #expect(throws: RecoveryInjectedPersistenceError.self) { try await recovery.recover(ownerID: owner, generation: 9) }
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
    }

    @Test("a discovery error wakes readers for books claimed earlier in the scan")
    func discoveryErrorWakesEarlierClaimedBookWaiter() async throws {
        let owner = UUID()
        let first = Book(userId: owner, title: "First", formatType: .pdf, fileURL: "Books/first.pdf")
        let second = Book(userId: owner, title: "Second", formatType: .pdf, fileURL: "Books/second.pdf")
        let firstToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: first.id, attemptID: UUID())
        let secondToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: second.id, attemptID: UUID())
        let persistence = RecoveryPersistence(
            jobs: [first.id: recoveryJob(book: first, token: firstToken), second.id: recoveryJob(book: second, token: secondToken)],
            currentGeneration: 9,
            pendingRecoveryFailureOnCall: 2
        )
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(rootURL: FileManager.default.temporaryDirectory,
            bookStore: OrderedRecoveryBookStore(orderedBooks: [first, second]), persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry))
        let joinedWaiter = Task { try await registry.awaitManagedSource(for: first) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: first.id)) { await Task.yield() }

        await #expect(throws: RecoveryInjectedPersistenceError.self) { try await recovery.recover(ownerID: owner, generation: 9) }
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
    }

    @Test("recovery adopts verified same-owner artifacts from an older generation")
    func adoptsOwnedVerifiedArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingURL = root.appendingPathComponent("Books/owned.staging")
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: stagingURL)
        let owner = UUID()
        let otherOwner = UUID()
        let book = Book(userId: owner, title: "Owned", formatType: .epub, fileURL: "Books/owned.epub")
        let foreign = Book(userId: otherOwner, title: "Foreign", formatType: .epub, fileURL: "Books/foreign.epub")
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID())
        let sourceRevision = UUID()
        let stagingVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: stagingURL, materializationRevision: sourceRevision))
        let job = PendingBookMaterialization(
            token: oldToken,
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "source", materializationRevision: sourceRevision),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4,
            stagingRelativePath: "Books/owned.staging",
            destinationRelativePath: book.fileURL,
            phase: .prepared,
            preparedFileIdentifier: stagingVersion.fileIdentifier
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry())
        let resumed = RecoveryResumeRecorder()
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book, foreign]),
            persistence: persistence,
            lifecycle: lifecycle,
            resume: { book, token in await resumed.record(book: book, token: token) }
        )

        let adopted = try await recovery.recover(ownerID: owner, generation: 9)

        #expect(adopted.count == 1)
        #expect(adopted[0].bookID == book.id)
        #expect(adopted[0].ownerID == owner)
        #expect(adopted[0].accountGeneration == 9)
        #expect(adopted[0].attemptID != oldToken.attemptID)
        #expect(await persistence.adoptedBookIDs == [book.id])
        #expect(await resumed.tokens == adopted)
        #expect(await resumed.books.map(\.id) == [book.id])
    }

    @Test("recovery does not resume an adopted attempt after authenticated identity changes")
    func doesNotResumeAfterIdentityChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingURL = root.appendingPathComponent("Books/owned.staging")
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: stagingURL)
        let owner = UUID()
        let book = Book(userId: owner, title: "Owned", formatType: .epub, fileURL: "Books/owned.epub")
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID())
        let sourceRevision = UUID()
        let stagingVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: stagingURL, materializationRevision: sourceRevision))
        let job = PendingBookMaterialization(
            token: oldToken,
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "source", materializationRevision: sourceRevision),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4,
            stagingRelativePath: "Books/owned.staging",
            destinationRelativePath: book.fileURL,
            phase: .prepared,
            preparedFileIdentifier: stagingVersion.fileIdentifier
        )
        let resumed = RecoveryResumeRecorder()
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9),
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            resume: { book, token in await resumed.record(book: book, token: token) }
        )

        let adopted = try await recovery.recover(ownerID: owner, generation: 9, isCurrentIdentity: { false })

        #expect(adopted.isEmpty)
        #expect(await resumed.tokens.isEmpty)
    }

    @Test("retryable resume failures keep owner recovery incomplete")
    func retryableResumeFailureThrows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingURL = root.appendingPathComponent("Books/owned.staging")
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: stagingURL)
        let owner = UUID()
        let book = Book(userId: owner, title: "Owned", formatType: .epub, fileURL: "Books/owned.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID())
        let sourceRevision = UUID()
        let stagedVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: stagingURL, materializationRevision: sourceRevision))
        let job = PendingBookMaterialization(
            token: token, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "source", materializationRevision: sourceRevision),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Books/owned.staging",
            destinationRelativePath: book.fileURL, phase: .prepared,
            preparedFileIdentifier: stagedVersion.fileIdentifier
        )
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9),
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            resume: { _, _ in throw RecoveryResumeTestError.providerTemporarilyUnavailable }
        )

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
    }

    @Test("registered provider imports resume from their bookmark after relaunch")
    func resumesCopyingBookmarkJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Provider", formatType: .pdf, fileURL: "Books/provider.pdf")
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: oldToken, sourceKind: .securityScopedOriginal, sourceBookmark: Data([1, 2]),
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "provider", materializationRevision: UUID()),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Imports/old/content.partial",
            destinationRelativePath: book.fileURL, phase: .copying
        )
        let resumed = RecoveryResumeRecorder()
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9),
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            resume: { book, token in await resumed.record(book: book, token: token) }
        )

        let adopted = try await recovery.recover(ownerID: owner, generation: 9)

        #expect(adopted.count == 1)
        #expect(adopted.first?.bookID == book.id)
        #expect(await resumed.tokens == adopted)
    }

    @Test("unprepared job without a surviving source stays retryable")
    func unpreparedJobWithoutSourceRemainsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Missing source", formatType: .epub, fileURL: "Books/missing.epub")
        let job = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID()),
            sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: "Imports/source-missing.epub",
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "missing", materializationRevision: UUID()),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Imports/old/content.partial",
            destinationRelativePath: book.fileURL, phase: .copying
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            resume: { _, _ in throw RecoveryResumeTestError.providerTemporarilyUnavailable }
        )

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
        #expect(await persistence.adoptedBookIDs == [book.id])
    }

    @Test("invalid old-generation artifact is quarantined and remains retryable")
    func invalidOldGenerationArtifactIsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Corrupt stage", formatType: .pdf, fileURL: "Books/corrupt.pdf")
        let job = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: UUID()),
            sourceKind: .securityScopedOriginal, sourceBookmark: Data([1]), ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Imports/\(UUID().uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .prepared, preparedFileIdentifier: "missing-stage"
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry)
        )

        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) {
            await Task.yield()
        }

        #expect(try await recovery.recover(ownerID: owner, generation: 9).isEmpty)
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
        #expect(await persistence.quarantinedBookIDs == [book.id])
        #expect(try await recovery.recover(ownerID: owner, generation: 9).isEmpty)
        #expect(await persistence.quarantinedBookIDs == [book.id])
    }

    @Test("adoption CAS refusal wakes only the recovery-joined source waiter")
    func adoptionRefusalWakesJoinedSourceWaiter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingURL = root.appendingPathComponent("Books/refusal.staging")
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: stagingURL)
        let owner = UUID()
        let book = Book(userId: owner, title: "CAS refusal", formatType: .epub, fileURL: "Books/refusal.epub")
        let oldToken = BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID())
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: stagingURL, materializationRevision: revision))
        let job = PendingBookMaterialization(
            token: oldToken, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: version, expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Books/refusal.staging", destinationRelativePath: book.fileURL,
            phase: .prepared, preparedFileIdentifier: version.fileIdentifier
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9, refusesAdoption: true)
        let registry = BookSourceRegistry(currentGeneration: { 9 }, currentOwnerID: { owner }, managedURL: { _ in nil })
        let recovery = BookImportRecovery(
            rootURL: root, bookStore: RecoveryBookStore([book]), persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: registry)
        )
        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)) {
            await Task.yield()
        }

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
        #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
        #expect(await persistence.adoptedBookIDs.isEmpty)
    }

    @Test("waiting-for-picker recovery authorizes each new generation without rotating the attempt")
    func waitingForPickerReauthorizesOnRelogin() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Waiting for picker", formatType: .epub, fileURL: "Books/waiting.epub")
        let initial = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: owner, accountGeneration: 8, bookID: book.id, attemptID: UUID()),
            sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: nil, materializationRevision: UUID()),
            expectedSHA256: "aabb", expectedByteCount: 4,
            stagingRelativePath: "Imports/waiting/content.partial", destinationRelativePath: book.fileURL,
            phase: .paused, retryableErrorCode: "recovery_artifact_invalid"
        )
        let persistence = RecoveryPersistence(jobs: [book.id: initial], currentGeneration: 9)
        let recovery = BookImportRecovery(
            rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry())
        )

        #expect(try await recovery.recover(ownerID: owner, generation: 9).isEmpty)
        #expect(try await recovery.recover(ownerID: owner, generation: 10).isEmpty)
        #expect(await persistence.reauthorizedGenerations == [9, 10])
        #expect(await persistence.quarantinedBookIDs.isEmpty)
    }

    @Test("transient file verification error preserves the staged artifact")
    func transientVerificationFailurePreservesStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Protected stage", formatType: .pdf, fileURL: "Books/protected.pdf")
        let attemptID = UUID()
        let stagingPath = "Imports/\(attemptID.uuidString)/content.partial"
        let stagingURL = root.appendingPathComponent(stagingPath)
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: stagingURL)
        let job = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: owner, accountGeneration: 3, bookID: book.id, attemptID: attemptID),
            sourceKind: .securityScopedOriginal, sourceBookmark: Data([1]), ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            expectedByteCount: 4, stagingRelativePath: stagingPath,
            destinationRelativePath: book.fileURL, phase: .prepared, preparedFileIdentifier: "prepared"
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            fileVersionInspector: FailingRecoveryVersionInspector()
        )

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(await persistence.quarantinedBookIDs.isEmpty)
        #expect(await persistence.adoptedBookIDs.isEmpty)
    }

    @Test("recovery cannot retire an active copy and its claim blocks later starts")
    func recoverySkipsAndExcludesActiveAttempt() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Active copy", formatType: .pdf, fileURL: "Books/active.pdf")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token, sourceKind: .securityScopedOriginal, sourceBookmark: Data([1]), ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "provider", materializationRevision: UUID()),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Imports/active/content.partial",
            destinationRelativePath: book.fileURL, phase: .copying
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let drains = RecoveryDrainRecorder()
        let resumes = RecoveryResumeRecorder()
        let lifecycle = BookImportLifecycle(
            sourceRegistry: makeRegistry(),
            currentAccountGeneration: { 9 },
            drainBookWork: { _, _, _ in await drains.increment() }
        )
        let active = try #require(lifecycle.admitBookMaterialization(token))
        let competingToken = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let recovery = BookImportRecovery(
            rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: lifecycle,
            resume: { book, adoptedToken in
                #expect(lifecycle.admitBookMaterialization(competingToken)?.bookID == nil)
                guard let lease = lifecycle.admitBookMaterialization(adoptedToken) else {
                    throw RecoveryResumeTestError.providerTemporarilyUnavailable
                }
                defer { lease.release() }
                await resumes.record(book: book, token: adoptedToken)
            }
        )

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
        #expect(await drains.count == 0)
        #expect(await resumes.tokens.isEmpty)
        #expect(lifecycle.admitBookMaterialization(competingToken)?.bookID == nil)

        active.release()
        let recovered = try await recovery.recover(ownerID: owner, generation: 9)
        #expect(recovered.count == 1)
        #expect(await drains.count == 1)
        #expect(await resumes.tokens == recovered)
        let laterAttempt = try #require(lifecycle.admitBookMaterialization(competingToken))
        laterAttempt.release()
    }

    @Test("retry claim drains the exact prior attempt and transfers one owner lease")
    func retryClaimDrainsOldAttemptAndActivatesExactlyOnce() async throws {
        let owner = UUID()
        let bookID = UUID()
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry(), currentAccountGeneration: { 12 })
        let old = BookMaterializationToken(ownerID: owner, accountGeneration: 10, bookID: bookID, attemptID: UUID())
        let competing = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: bookID, attemptID: UUID())
        let competingAdmission = try #require(lifecycle.admitBookMaterialization(competing))
        let promotionGate = RetryDrainTestGate()
        let competingPromotion = Task {
            try await lifecycle.withPromotionPermit(token: competing) {
                await promotionGate.hold()
            }
        }
        #expect(await promotionGate.waitUntilEntered())
        #expect(lifecycle.claimAttemptRetry(
            accountPermit: AccountMutationPermit(ownerID: owner, accountGeneration: 12), retiring: old
        ) == nil)
        await promotionGate.release()
        try await competingPromotion.value
        competingAdmission.release()
        lifecycle.fenceAccount(ownerID: owner, generation: 9)
        await lifecycle.drainAccount(owner, generation: 9)
        #expect(lifecycle.activateAccount(ownerID: owner, generation: 12))

        let oldAdmission = try #require(lifecycle.admitBookMaterialization(old))
        let claim = try #require(lifecycle.claimAttemptRetry(
            accountPermit: AccountMutationPermit(ownerID: owner, accountGeneration: 12), retiring: old
        ))
        defer { claim.release() }

        let drainCompletion = RetryDrainCompletionRecorder()
        let drain = Task {
            await drainCompletion.markStarted()
            let drained = await claim.drain()
            await drainCompletion.markFinished(drained)
        }
        #expect(await drainCompletion.waitUntilStarted())
        #expect(await waitUntilBookAttemptDrainWaiter(lifecycle: lifecycle, token: old))
        #expect(!(await drainCompletion.isFinished()))
        oldAdmission.release()
        #expect(await drainCompletion.waitUntilFinished())
        #expect(await drainCompletion.drainedToken == old)

        let adopted = BookMaterializationToken(ownerID: owner, accountGeneration: 12, bookID: bookID, attemptID: UUID())
        #expect(lifecycle.admitBookRegistration(ownerID: owner, generation: 12, bookID: bookID) == nil)
        let activation = try #require(claim.activate(adopted))
        #expect(claim.activate(adopted) == nil)
        #expect(lifecycle.admitBookMaterialization(old) == nil)
        let joinedRegistration = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 12, bookID: bookID))
        joinedRegistration.release()
        activation.release()
        claim.release()
        let registration = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 12, bookID: bookID))
        registration.release()
    }

    @Test("account drain waits for an owned retry claim")
    func accountDrainWaitsForRetryClaim() async throws {
        let owner = UUID()
        let bookID = UUID()
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry(), currentAccountGeneration: { 12 })
        let old = BookMaterializationToken(ownerID: owner, accountGeneration: 10, bookID: bookID, attemptID: UUID())
        let claim = try #require(lifecycle.claimAttemptRetry(
            accountPermit: AccountMutationPermit(ownerID: owner, accountGeneration: 12), retiring: old
        ))
        let drainCompletion = RetryDrainCompletionRecorder()
        let admissionProbe = BookMaterializationToken(ownerID: owner, accountGeneration: 12, bookID: UUID(), attemptID: UUID())
        let probeAdmission = try #require(lifecycle.admitBookMaterialization(admissionProbe))
        probeAdmission.release()
        let drain = Task {
            await drainCompletion.markStarted()
            await lifecycle.drainAccount(owner, generation: 12)
            await drainCompletion.markFinished()
        }
        #expect(await drainCompletion.waitUntilStarted())
        #expect(await waitForAdmissionClosure(lifecycle: lifecycle, token: admissionProbe))
        #expect(!(await drainCompletion.isFinished()))
        claim.release()
        #expect(await drainCompletion.waitUntilFinished())
        #expect(lifecycle.claimAttemptRetry(
            accountPermit: AccountMutationPermit(ownerID: owner, accountGeneration: 12), retiring: old
        ) == nil)
    }

    @Test("registration admission prevents recovery from claiming before materialization starts")
    func registrationAdmissionClosesPickerRace() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "New registration", formatType: .epub, fileURL: "Books/new.pdf")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token, sourceKind: .securityScopedOriginal, sourceBookmark: Data([1]), ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: "provider", materializationRevision: UUID()),
            expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
            expectedByteCount: 4, stagingRelativePath: "Imports/new/content.partial",
            destinationRelativePath: book.fileURL, phase: .registered
        )
        let persistence = RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9)
        let drains = RecoveryDrainRecorder()
        let resumes = RecoveryResumeRecorder()
        let lifecycle = BookImportLifecycle(
            sourceRegistry: makeRegistry(),
            currentAccountGeneration: { 9 },
            drainBookWork: { _, _, _ in await drains.increment() }
        )
        // Simulate a duplicate-content reservation whose selected placeholder
        // ID differs from the canonical pending BookID returned by storage.
        let placeholderBookID = UUID()
        let registration = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: placeholderBookID))
        let recovery = BookImportRecovery(
            rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: lifecycle,
            resume: { book, adoptedToken in
                #expect(lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: book.id)?.bookID == nil)
                let unrelatedRegistration = lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: UUID())
                #expect(unrelatedRegistration?.bookID != nil)
                unrelatedRegistration?.release()
                guard let lease = lifecycle.admitBookMaterialization(adoptedToken) else {
                    throw RecoveryResumeTestError.providerTemporarilyUnavailable
                }
                defer { lease.release() }
                await resumes.record(book: book, token: adoptedToken)
            }
        )

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
        #expect(await drains.count == 0)
        registration.release()

        let recovered = try await recovery.recover(ownerID: owner, generation: 9)
        #expect(recovered.count == 1)
        #expect(await drains.count == 1)
        #expect(await resumes.tokens == recovered)
    }

    @Test("materialization transfer releases owner registration gate while retaining book attempt gate")
    func registrationAdmissionTransfersToBookAttempt() throws {
        let owner = UUID()
        let bookA = UUID()
        let bookB = UUID()
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry())
        let tokenA = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: bookA, attemptID: UUID())
        let registration = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: bookA))

        // This is the synchronous handoff used by coordinator.materialize:
        // take the book-specific lease before releasing the owner gate.
        let attempt = try #require(lifecycle.admitBookMaterialization(tokenA))
        registration.release()

        let independentRecovery = try #require(lifecycle.claimBookRecovery(ownerID: owner, generation: 9, bookID: bookB))
        #expect(lifecycle.claimBookRecovery(ownerID: owner, generation: 9, bookID: bookA)?.bookID == nil)
        independentRecovery.release()
        attempt.release()
    }

    @Test("recovery copy releases owner-wide admission while keeping its book attempt claimed")
    func recoveryPromotionAllowsUnrelatedRegistration() async throws {
        let owner = UUID()
        let recoveringBook = UUID()
        let unrelatedBook = UUID()
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry())
        let token = BookMaterializationToken(
            ownerID: owner,
            accountGeneration: 9,
            bookID: recoveringBook,
            attemptID: UUID()
        )
        let claim = try #require(lifecycle.claimBookRecovery(
            ownerID: owner,
            generation: 9,
            bookID: recoveringBook
        ))

        #expect(lifecycle.admitBookRegistration(
            ownerID: owner,
            generation: 9,
            bookID: recoveringBook
        ) == nil)
        let unrelatedRegistration = try #require(lifecycle.admitBookRegistration(
            ownerID: owner,
            generation: 9,
            bookID: unrelatedBook
        ))

        #expect(claim.promoteMaterialization(token) == nil)
        #expect(claim.allowMaterialization(token))
        let activeAttempt = try #require(claim.promoteMaterialization(token))
        claim.release()
        #expect(lifecycle.admitBookRegistration(
            ownerID: owner,
            generation: 9,
            bookID: recoveringBook
        )?.bookID == nil)
        let anotherUnrelatedRegistration = try #require(lifecycle.admitBookRegistration(
            ownerID: owner,
            generation: 9,
            bookID: UUID()
        ))
        let pickerWaiter = Task {
            await lifecycle.waitForBookRecoveryClaimIfPresent(ownerID: owner, generation: 9, bookID: recoveringBook)
        }
        var waiterPolls = 0
        while !lifecycle.hasRecoveryClaimWaiterForTesting(ownerID: owner, generation: 9, bookID: recoveringBook),
              waiterPolls < 10_000 {
            waiterPolls += 1
            await Task.yield()
        }
        #expect(lifecycle.hasRecoveryClaimWaiterForTesting(ownerID: owner, generation: 9, bookID: recoveringBook))
        unrelatedRegistration.release()
        anotherUnrelatedRegistration.release()
        activeAttempt.release()
        #expect(await pickerWaiter.value)
        let sameBookAfterRecovery = try #require(lifecycle.admitBookRegistration(
            ownerID: owner,
            generation: 9,
            bookID: recoveringBook
        ))
        sameBookAfterRecovery.release()
    }

    @Test("cancelling a picker waiting on recovery removes its parked continuation")
    func cancelledRecoveryAdmissionWaitDoesNotResumeIntoRegistration() async throws {
        let owner = UUID()
        let bookID = UUID()
        let lifecycle = BookImportLifecycle(sourceRegistry: makeRegistry())
        let claim = try #require(lifecycle.claimBookRecovery(ownerID: owner, generation: 9, bookID: bookID))

        let waiter = Task {
            await lifecycle.waitForBookRecoveryClaimIfPresent(
                ownerID: owner,
                generation: 9,
                bookID: bookID
            )
        }
        var registrationPolls = 0
        while !lifecycle.hasRecoveryClaimWaiterForTesting(ownerID: owner, generation: 9, bookID: bookID),
              registrationPolls < 10_000 {
            registrationPolls += 1
            await Task.yield()
        }
        #expect(lifecycle.hasRecoveryClaimWaiterForTesting(ownerID: owner, generation: 9, bookID: bookID))
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(!lifecycle.hasRecoveryClaimWaiterForTesting(ownerID: owner, generation: 9, bookID: bookID))

        claim.release()
        let admission = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: bookID))
        admission.release()
    }

    @Test("failed recovery resume wakes source waiters and leaves the book retryable")
    func failedResumeWakesJoinedSourceWaiter() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Recovering", formatType: .epub, fileURL: "Books/recovering.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token,
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: nil, materializationRevision: UUID()),
            expectedSHA256: "aabb",
            expectedByteCount: 4,
            stagingRelativePath: "Imports/recovering/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .copying
        )
        let registry = BookSourceRegistry(
            currentGeneration: { 9 },
            currentOwnerID: { owner },
            managedURL: { _ in nil }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        let recovery = BookImportRecovery(
            rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]),
            persistence: RecoveryPersistence(jobs: [book.id: job], currentGeneration: 9),
            lifecycle: lifecycle,
            resume: { _, _ in throw RecoveryResumeTestError.providerTemporarilyUnavailable }
        )

        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        var waiterPolls = 0
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)),
              waiterPolls < 10_000 {
            waiterPolls += 1
            await Task.yield()
        }
        #expect(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id))

        await #expect(throws: BookImportRecovery.RecoveryError.retryableWorkRemains) {
            try await recovery.recover(ownerID: owner, generation: 9)
        }
       #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.awaitManagedSource(for: book)
        }
        let pickerRetry = try #require(lifecycle.admitBookRegistration(ownerID: owner, generation: 9, bookID: book.id))
        pickerRetry.release()
    }

    @Test("activating a retry makes prior attempt failures stale before source registration")
    func retryActivationClearsPreviousAttemptFailure() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Retry source", formatType: .epub, fileURL: "Books/retry.epub")
        let registry = BookSourceRegistry(
            currentGeneration: { 9 },
            currentOwnerID: { owner },
            managedURL: { _ in nil }
        )
        await registry.failPendingSource(
            ownerID: owner,
            generation: 9,
            bookID: book.id,
            error: StaleAttemptSourceFailure.previousAttempt
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        let retryToken = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        #expect(lifecycle.activatePromotionAttempt(retryToken))

        let joinedWaiter = Task { try await registry.awaitManagedSource(for: book) }
        var waiterPolls = 0
        while !(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id)),
              waiterPolls < 10_000 {
            waiterPolls += 1
            await Task.yield()
        }
        #expect(await registry.hasManagedWaiterForTesting(ownerID: owner, generation: 9, bookID: book.id))

        await registry.failPendingSource(ownerID: owner, generation: 9, bookID: book.id)
       #expect(await joinedWaiterFailedUnavailable(joinedWaiter))
    }

    @Test("recovery with no pending jobs leaves active owner admission open")
    func noCandidatesDoNotFenceOwner() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Already managed", formatType: .epub, fileURL: "Books/managed.epub")
        let fenceCounter = RecoveryFenceCounter()
        let lifecycle = BookImportLifecycle(
            sourceRegistry: makeRegistry(),
            cancelOwnerWork: { _, _ in fenceCounter.increment() }
        )
        let recovery = BookImportRecovery(
            rootURL: FileManager.default.temporaryDirectory,
            bookStore: RecoveryBookStore([book]),
            persistence: RecoveryPersistence(jobs: [:], currentGeneration: 9),
            lifecycle: lifecycle
        )

        let adopted = try await recovery.recover(ownerID: owner, generation: 9)

        #expect(adopted.isEmpty)
        #expect(fenceCounter.value == 0)
        #expect(lifecycle.admits(ownerID: owner, generation: 9))
    }

    @Test("ready owned source is removed only after the managed destination is reverified")
    func readyOwnedSourceCleanupRechecksManagedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Ready", formatType: .epub, fileURL: "Books/ready.epub")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let sourceRelative = "Imports/\(token.attemptID.uuidString)/source.epub"
        let sourceURL = root.appendingPathComponent(sourceRelative)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified bytes".utf8).write(to: sourceURL)
        let destinationURL = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified bytes".utf8).write(to: destinationURL)
        let revision = UUID()
        let probe = try await CoordinatedSourceProbe().probe(destinationURL, materializationRevision: revision)
        let readyJob = PendingBookMaterialization(
            token: token, sourceKind: .ownedStaging, sourceBookmark: nil,
            ownedSourceRelativePath: sourceRelative,
            sourceVersion: probe.version, expectedSHA256: probe.sha256,
            expectedByteCount: probe.byteCount, stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .ready,
            destinationFileIdentifier: probe.version.fileIdentifier,
            promotionRevision: revision
        )
        let persistence = RecoveryPersistence(
            jobs: [book.id: readyJob], currentGeneration: 9,
            fingerprints: [book.id: BookFileFingerprint(bookID: book.id, ownerID: owner, sha256: probe.sha256, version: probe.version)]
        )
        let cleanup = RecoveryCleanupRecorder()
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            prepareOwnedSourceCleanup: { token in await cleanup.prepare(token); return true }
        )

        #expect(try await recovery.recover(ownerID: owner, generation: 9).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(await cleanup.tokens == [token])
    }

    @Test("ready owned source survives if managed destination bytes changed")
    func readyOwnedSourceIsPreservedWhenManagedBytesChanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookImportRecovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let book = Book(userId: owner, title: "Ready", formatType: .pdf, fileURL: "Books/ready.pdf")
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 9, bookID: book.id, attemptID: UUID())
        let sourceRelative = "Imports/\(token.attemptID.uuidString)/source.pdf"
        let sourceURL = root.appendingPathComponent(sourceRelative)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified bytes".utf8).write(to: sourceURL)
        let destinationURL = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("replaced bytes".utf8).write(to: destinationURL)
        let revision = UUID()
        let originalProbe = try await CoordinatedSourceProbe().probe(sourceURL, materializationRevision: revision)
        let managedVersion = try #require(try CoordinatedSourceProbe.version(at: destinationURL, revision: revision))
        let readyJob = PendingBookMaterialization(
            token: token, sourceKind: .ownedStaging, sourceBookmark: nil,
            ownedSourceRelativePath: sourceRelative,
            sourceVersion: originalProbe.version, expectedSHA256: originalProbe.sha256,
            expectedByteCount: originalProbe.byteCount, stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .ready,
            destinationFileIdentifier: managedVersion.fileIdentifier,
            promotionRevision: revision
        )
        let persistence = RecoveryPersistence(
            jobs: [book.id: readyJob], currentGeneration: 9,
            fingerprints: [book.id: BookFileFingerprint(bookID: book.id, ownerID: owner, sha256: originalProbe.sha256, version: managedVersion)]
        )
        let cleanup = RecoveryCleanupRecorder()
        let recovery = BookImportRecovery(
            rootURL: root,
            bookStore: RecoveryBookStore([book]),
            persistence: persistence,
            lifecycle: BookImportLifecycle(sourceRegistry: makeRegistry()),
            prepareOwnedSourceCleanup: { token in await cleanup.prepare(token); return true }
        )

        #expect(try await recovery.recover(ownerID: owner, generation: 9).isEmpty)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(await cleanup.tokens.isEmpty)
    }

    @MainActor
    @Test("background expiration pauses only the still-authenticated owner generation")
    func backgroundExpirationIsIdentityScoped() async {
        let owner = UUID()
        let otherOwner = UUID()
        let pauses = RecoveryPauseRecorder()
        let activation = BookImportActivationToken(ownerID: owner, generation: 9, transitionEpoch: 1)

        await BackgroundSyncLifecycle.pauseImportsIfCurrent(
            ownerID: owner,
            generation: 9,
            currentOwnerID: otherOwner,
            currentGeneration: 9,
            activationToken: activation,
            pauseAccount: { owner, generation, _ in await pauses.record(ownerID: owner, generation: generation) }
        )
        await BackgroundSyncLifecycle.pauseImportsIfCurrent(
            ownerID: owner,
            generation: 9,
            currentOwnerID: owner,
            currentGeneration: 10,
            activationToken: activation,
            pauseAccount: { owner, generation, _ in await pauses.record(ownerID: owner, generation: generation) }
        )
        await BackgroundSyncLifecycle.pauseImportsIfCurrent(
            ownerID: owner,
            generation: 9,
            currentOwnerID: owner,
            currentGeneration: 9,
            activationToken: activation,
            pauseAccount: { owner, generation, _ in await pauses.record(ownerID: owner, generation: generation) }
        )

        let calls = await pauses.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == owner)
        #expect(calls.first?.1 == 9)
    }
}

private enum RecoveryResumeTestError: Error { case providerTemporarilyUnavailable }
private enum RecoveryInjectedPersistenceError: Error { case lookup; case adoption }

private func recoveryJob(book: Book, token: BookMaterializationToken) -> PendingBookMaterialization {
    PendingBookMaterialization(token: token, sourceKind: .ownedStaging, sourceBookmark: nil,
        ownedSourceRelativePath: "Imports/lookup/source.epub",
        sourceVersion: ManagedFileVersion(byteCount: 4, modificationDate: Date(timeIntervalSince1970: 1), fileIdentifier: nil, materializationRevision: UUID()),
        expectedSHA256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7",
        expectedByteCount: 4, stagingRelativePath: "Imports/lookup/content.partial",
        destinationRelativePath: book.fileURL, phase: .copying)
}
private enum StaleAttemptSourceFailure: Error { case previousAttempt }

private struct FailingRecoveryVersionInspector: ManagedFileVersionInspecting {
    func managedFileVersion(at absoluteURL: URL, materializationRevision: UUID) throws -> ManagedFileVersion? {
        throw RecoveryResumeTestError.providerTemporarilyUnavailable
    }
}

private actor RecoveryResumeRecorder {
    private(set) var books: [Book] = []
    private(set) var tokens: [BookMaterializationToken] = []
    func record(book: Book, token: BookMaterializationToken) {
        books.append(book)
        tokens.append(token)
    }
}

private actor RetryDrainTestGate {
    private var entered = false
    private var released = false
    private var releaseContinuation: AsyncStream<Void>.Continuation?

    func hold() async {
        entered = true
        guard !released else { return }
        let stream = AsyncStream<Void> { continuation in
            releaseContinuation = continuation
        }
        await withTaskCancellationHandler {
            for await _ in stream { break }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        releaseContinuation?.yield(())
        releaseContinuation?.finish()
        releaseContinuation = nil
    }

    private func cancelWait() {
        releaseContinuation?.finish()
        releaseContinuation = nil
    }
}

private actor RetryDrainCompletionRecorder {
    private var started = false
    private var finished = false
    private(set) var drainedToken: BookMaterializationToken?

    func markStarted() { started = true }
    func markFinished(_ token: RetiredBookMaterializationAttempt? = nil) { drainedToken = token?.token; finished = true }
    func isFinished() -> Bool { finished }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }

    func waitUntilFinished() async -> Bool {
        for _ in 0..<200 {
            if finished { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return finished
    }
}


private func joinedWaiterFailedUnavailable(_ waiter: Task<ManagedBookSource, Error>) async -> Bool {
    let gate = ManagedWaiterCompletionGate()
    let observer = Task {
        do {
            _ = try await waiter.value
            gate.resolve(false)
        } catch {
            gate.resolve((error as? BookSourceRegistryError) == .unavailable)
        }
    }
    let timeout = Task {
        try? await Task.sleep(for: .seconds(2))
        gate.resolve(false)
    }
    let result = await gate.wait()
    timeout.cancel()
    if !result {
        waiter.cancel()
        observer.cancel()
    }
    return result
}

private final class ManagedWaiterCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolution: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(returning: resolution)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard resolution == nil else { lock.unlock(); return }
        resolution = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private func waitUntilBookAttemptDrainWaiter(lifecycle: BookImportLifecycle, token: BookMaterializationToken) async -> Bool {
    for _ in 0..<200 {
        if lifecycle.hasBookAttemptDrainWaiterForTesting(
            ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID
        ) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return lifecycle.hasBookAttemptDrainWaiterForTesting(
        ownerID: token.ownerID, generation: token.accountGeneration, bookID: token.bookID
    )
}

private func waitForAdmissionClosure(lifecycle: BookImportLifecycle, token: BookMaterializationToken) async -> Bool {
    for _ in 0..<200 {
        guard let admission = lifecycle.admitBookMaterialization(token) else { return true }
        admission.release()
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private actor RecoveryDrainRecorder {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor RecoveryPauseRecorder {
    private(set) var calls: [(UserID, UInt64)] = []
    func record(ownerID: UserID, generation: UInt64) { calls.append((ownerID, generation)) }
}

private actor RecoveryCleanupRecorder {
    private(set) var tokens: [BookMaterializationToken] = []
    func prepare(_ token: BookMaterializationToken) { tokens.append(token) }
}

private actor RecoveryPersistence: BookImportPersistence {
    private var jobs: [BookID: PendingBookMaterialization]
    private let fingerprints: [BookID: BookFileFingerprint]
    private let currentGeneration: UInt64
    private let refusesAdoption: Bool
    private let pendingRecoveryFailureOnCall: Int?
    private let adoptionThrows: Bool
    private var recoveryLookupCalls = 0
    private(set) var adoptedBookIDs: [BookID] = []
    private(set) var quarantinedBookIDs: [BookID] = []
    private(set) var reauthorizedGenerations: [UInt64] = []
    init(
        jobs: [BookID: PendingBookMaterialization],
        currentGeneration: UInt64,
        fingerprints: [BookID: BookFileFingerprint] = [:],
        refusesAdoption: Bool = false,
        pendingRecoveryFailureOnCall: Int? = nil,
        adoptionThrows: Bool = false
    ) {
        self.jobs = jobs
        self.currentGeneration = currentGeneration
        self.fingerprints = fingerprints
        self.refusesAdoption = refusesAdoption
        self.pendingRecoveryFailureOnCall = pendingRecoveryFailureOnCall
        self.adoptionThrows = adoptionThrows
    }
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        guard let job = jobs[bookID], job.token.ownerID == ownerID,
              job.token.accountGeneration == currentGeneration else { return nil }
        return job
    }
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? {
        recoveryLookupCalls += 1
        if recoveryLookupCalls == pendingRecoveryFailureOnCall { throw RecoveryInjectedPersistenceError.lookup }
        guard let job = jobs[bookID], job.token.ownerID == ownerID else { return nil }
        return job
    }
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? {
        if adoptionThrows { throw RecoveryInjectedPersistenceError.adoption }
        guard !refusesAdoption,
              let job = jobs[expectedToken.bookID], job.token == expectedToken,
              currentOwnerID == expectedToken.ownerID,
              verifiedArtifacts.preparedFileIdentifier == jobs[expectedToken.bookID]?.preparedFileIdentifier else { return nil }
        adoptedBookIDs.append(expectedToken.bookID)
        let token = BookMaterializationToken(ownerID: currentOwnerID, accountGeneration: currentGeneration, bookID: expectedToken.bookID, attemptID: newAttemptID)
        jobs[expectedToken.bookID] = PendingBookMaterialization(
            token: token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: verifiedArtifacts.stagingRelativePath,
            destinationRelativePath: verifiedArtifacts.destinationRelativePath,
            phase: job.phase, retryableErrorCode: job.retryableErrorCode,
            preparedFileIdentifier: verifiedArtifacts.preparedFileIdentifier,
            destinationFileIdentifier: verifiedArtifacts.destinationFileIdentifier,
            promotionRevision: verifiedArtifacts.promotionRevision
        )
        return token
    }
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? {
        guard let job = jobs[expectedToken.bookID], job.token == expectedToken,
              currentOwnerID == expectedToken.ownerID, newAttemptID != expectedToken.attemptID else { return nil }
        quarantinedBookIDs.append(expectedToken.bookID)
        let token = BookMaterializationToken(ownerID: currentOwnerID, accountGeneration: currentGeneration, bookID: expectedToken.bookID, attemptID: newAttemptID)
        jobs[expectedToken.bookID] = PendingBookMaterialization(
            token: token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: "Imports/\(newAttemptID.uuidString)/content.partial",
            destinationRelativePath: job.destinationRelativePath, phase: .paused,
            retryableErrorCode: "recovery_artifact_invalid"
        )
        return token
    }
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? {
        guard let job = jobs[expectedToken.bookID], job.token == expectedToken,
              currentOwnerID == expectedToken.ownerID, job.phase == .paused,
              job.retryableErrorCode == "recovery_artifact_invalid" || job.retryableErrorCode == "recovery_source_unavailable" else { return nil }
        reauthorizedGenerations.append(currentGeneration)
        let token = BookMaterializationToken(ownerID: currentOwnerID, accountGeneration: currentGeneration, bookID: expectedToken.bookID, attemptID: expectedToken.attemptID)
        jobs[expectedToken.bookID] = PendingBookMaterialization(
            token: token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath,
            phase: job.phase, retryableErrorCode: job.retryableErrorCode,
            preparedFileIdentifier: job.preparedFileIdentifier,
            destinationFileIdentifier: job.destinationFileIdentifier,
            promotionRevision: job.promotionRevision
        )
        return token
    }
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration { fatalError("unused") }
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? { fatalError("unused") }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool {
        guard let job = jobs[token.bookID], job.token == token, job.phase == from else { return false }
        jobs[token.bookID] = PendingBookMaterialization(
            token: token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath,
            phase: to, retryableErrorCode: job.retryableErrorCode,
            preparedFileIdentifier: job.preparedFileIdentifier,
            destinationFileIdentifier: job.destinationFileIdentifier,
            promotionRevision: job.promotionRevision
        )
        return true
    }
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool { fatalError("unused") }
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool { fatalError("unused") }
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool { false }
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { false }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        guard let fingerprint = fingerprints[bookID], fingerprint.ownerID == ownerID else { return nil }
        return fingerprint
    }
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {}
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {}

    // Explicit negative results for operations outside this fixture's controlled scenario.
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { false }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { false }
    func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit? { nil }
    func readingPermit(forManagedFingerprint fingerprint: BookFileFingerprint, expectedRelativePath: String, generation: UInt64) async throws -> BookReadingPermit? { nil }
    func parkSampleRepair(book: Book, token: BookMaterializationToken) async -> SampleRepairParkingOutcome { .writeFailed }
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool { false }
    func retryExpectation(bookID: BookID, ownerID: UserID, accountPermit: AccountMutationPermit) async throws -> BookImportRetryExpectation? { nil }
    func retryPendingMaterialization(expected: BookImportRetryExpectation, accountPermit: AccountMutationPermit, newSource: PendingBookMaterialization, verifiedSourceSHA256: String, verifiedSourceByteCount: Int64, verifiedSourceVersion: ManagedFileVersion, retiredAttempt: RetiredBookMaterializationAttempt) async throws -> BookRegistration? { nil }
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool { false }
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? { try await pendingMaterialization(bookID: bookID, ownerID: ownerID) }
    func pendingMaterializationsForDeletionCleanup(ownerID: UserID) async throws -> [PendingBookMaterialization] { [] }
    func isBookPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool { false }
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool { false }
    func sampleRepairFingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? { try await fingerprint(bookID: bookID, ownerID: ownerID) }
    func recordServerAcceptance(permit: BookReadingPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { false }
    func recordServerAcceptance(accountPermit: AccountMutationPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { false }
}

private struct RecoveryBookStore: BookStore {
    let booksByID: [BookID: Book]
    init(_ books: [Book]) { booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) }) }
    func books(for userId: UserID) async throws -> [Book] { booksByID.values.filter { $0.userId == userId } }
    func book(_ id: BookID) async throws -> Book? { booksByID[id] }
    func upsert(_ book: Book) async throws {}
    func delete(_ id: BookID) async throws {}
}

private struct OrderedRecoveryBookStore: BookStore {
    let orderedBooks: [Book]
    func books(for userId: UserID) async throws -> [Book] { orderedBooks.filter { $0.userId == userId } }
    func book(_ id: BookID) async throws -> Book? { orderedBooks.first { $0.id == id } }
    func upsert(_ book: Book) async throws {}
    func delete(_ id: BookID) async throws {}
}

private final class RecoveryFenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private func makeRegistry() -> BookSourceRegistry {
    BookSourceRegistry(currentGeneration: { 9 }, managedURL: { _ in nil })
}

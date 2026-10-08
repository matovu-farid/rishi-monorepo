import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import rishi

@Suite("Sample repair deletion denial")
struct BookSampleRepairDenialTests {
    @Test("failed deletion before claim transfer restores admission with the parked token")
    func failedDeletionBeforeTransferRestoresParkedRepair() async throws {
        let fixture = try makeFixture()
        let claim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ))
        let witness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        claim.release()

        #expect(fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: witness, parkedRepairToken: fixture.parkedToken
        ))
        #expect(fixture.lifecycle.admits(ownerID: fixture.ownerID, generation: fixture.generation))
        let parkedClaim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.parkedToken
        ))
        #expect(parkedClaim.allowMaterialization(fixture.parkedToken))
        #expect(parkedClaim.promoteMaterialization(fixture.parkedToken) == nil)
        parkedClaim.release()

        let retryClaim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.parkedToken
        ))
        let freshToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        #expect(retryClaim.allowMaterialization(freshToken))
        let freshAdmission = try #require(retryClaim.promoteMaterialization(freshToken))
        freshAdmission.release()
        retryClaim.release()
    }

    @Test("failed deletion after claim transfer restores a parked token without reviving the transferred token")
    func failedDeletionAfterTransferRestoresParkedRepair() async throws {
        let fixture = try makeFixture()
        let claim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ))
        #expect(claim.allowMaterialization(fixture.retiredToken))
        #expect(fixture.lifecycle.activatePromotionAttempt(fixture.retiredToken))
        let admission = try #require(claim.promoteMaterialization(fixture.retiredToken))
        let witness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        admission.release()

        #expect(witness.retiredToken == fixture.retiredToken)
        #expect(fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: witness, parkedRepairToken: fixture.parkedToken
        ))
        #expect(fixture.lifecycle.admits(ownerID: fixture.ownerID, generation: fixture.generation))
        let retiredClaim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.retiredToken
        ))
        #expect(retiredClaim.allowMaterialization(fixture.retiredToken))
        #expect(!fixture.lifecycle.activatePromotionAttempt(fixture.retiredToken))
        retiredClaim.release()
        let parkedClaim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.parkedToken
        ))
        parkedClaim.release()
    }

    @Test("an earlier deletion witness cannot reopen admission after a later deletion")
    func staleDeletionWitnessCannotRestoreLaterRetirement() throws {
        let fixture = try makeFixture()
        let first = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        #expect(fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: first, parkedRepairToken: fixture.parkedToken
        ))
        let second = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )

        #expect(second.operationID != first.operationID)
        #expect(!fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: first, parkedRepairToken: fixture.parkedToken
        ))
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ) == nil)
    }

    @Test("a successful deletion leaves the retirement fence closed")
    func successfulDeletionKeepsFenceClosed() throws {
        let fixture = try makeFixture()
        let witness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )

        // The successful tombstone path intentionally has no restoration call.
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ) == nil)
        #expect(!fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: BookDeletionRetirementWitness(
                ownerID: witness.ownerID, generation: witness.generation, bookID: witness.bookID,
                operationID: UUID(), retiredToken: witness.retiredToken
            ), parkedRepairToken: fixture.parkedToken
        ))
    }

    @Test("provisional rollback admits only the witnessed recovery claim and abort preserves the witness")
    func provisionalRollbackLeaseScopesRecoveryAndAbortRefences() throws {
        let fixture = try makeFixture()
        let witness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )

        let lease = try #require(fixture.lifecycle.beginProvisionalDeletionRollback(witness: witness))
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(fixture.lifecycle.isCurrentProvisionalDeletionRollbackLease(lease))
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ) == nil)
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.parkedToken
        ) == nil)

        let recoveryClaim = try #require(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id,
            expectedToken: fixture.parkedToken, provisionalRollbackLease: lease
        ))
        #expect(recoveryClaim.allowMaterialization(fixture.parkedToken))
        recoveryClaim.release()

        fixture.lifecycle.abortProvisionalDeletionRollback(lease)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.isCurrentProvisionalDeletionRollbackLease(lease))
        let retriedLease = try #require(fixture.lifecycle.beginProvisionalDeletionRollback(witness: witness))
        fixture.lifecycle.abortProvisionalDeletionRollback(retriedLease)
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ) == nil)
    }

    @MainActor
    @Test("failed tombstone conflict preserves bytes, fences the book, and leaves another job untouched")
    func targetedRecoveryConflictPreservesArtifactsAndUnrelatedJob() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let competingBytes = Data("user replacement".utf8)
        let coordinator = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            beforeRepairPromotion: { url in try competingBytes.write(to: url) }
        )

        await #expect(throws: Error.self) {
            _ = try await coordinator.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }
        let staged = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        let preparedFileIdentifier = try #require(staged.preparedFileIdentifier)
        let stagedURL = fixture.root.appendingPathComponent(staged.stagingRelativePath)
        let stagedBytes = try Data(contentsOf: stagedURL)

        let otherBook = Book(
            userId: fixture.ownerID, title: "Other pending book", formatType: .epub,
            fileURL: "Books/other-pending.epub"
        )
        let otherToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: otherBook.id, attemptID: UUID()
        )
        let otherBytes = Data("different pending source bytes".utf8)
        let otherSourceURL = fixture.root.appendingPathComponent("other-pending-source.epub")
        try otherBytes.write(to: otherSourceURL)
        let otherSourceVersion = try #require(try CoordinatedSourceProbe.version(
            at: otherSourceURL, revision: UUID()
        ))
        let otherDigest = SHA256.hash(data: otherBytes).map { String(format: "%02x", $0) }.joined()
        let otherJob = PendingBookMaterialization(
            token: otherToken, sourceKind: .ownedStaging, sourceBookmark: nil,
            ownedSourceRelativePath: "other-pending-source.epub", sourceVersion: otherSourceVersion,
            expectedSHA256: otherDigest,
            expectedByteCount: Int64(otherBytes.count),
            stagingRelativePath: "Imports/\(otherToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: otherBook.fileURL, phase: .registered
        )
        #expect(try await fixture.persistence.reserveRegistration(book: otherBook, job: otherJob).disposition == .registered)
        try await fixture.books.upsert(otherBook)

        let recovery = BookImportRecovery(
            rootURL: fixture.root, bookStore: fixture.books,
            persistence: fixture.persistence, lifecycle: fixture.lifecycle
        )
        let rollbackCoordinator = fixture.makeCoordinator()
        let witnessBox = DeletionWitnessBox()
        let storage = BookFileStorage(rootURL: fixture.root, bookStore: fixture.books, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: fixture.books,
            currentUserId: { fixture.ownerID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { fixture.ownerID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in },
            beforeBookDeleted: { book in
                let witness = await fixture.lifecycle.drainBookForDeletion(
                    ownerID: book.userId, generation: fixture.generation, bookID: book.id
                )
                await witnessBox.set(witness)
                return witness
            },
            restoreBookAfterFailedRetirement: { book, witness in
                await rollbackCoordinator.restoreBookAfterFailedRetirement(
                    book: book,
                    witness: witness,
                    expectedGeneration: fixture.generation,
                    recoverStartedSampleRepair: { recoveredBook, token, lease in
                        await recovery.recoverBook(
                            book: recoveredBook, expectedToken: token, rollbackLease: lease,
                            isCurrentIdentity: { true }
                        )
                    }
                )
            },
            onBookDeleted: { _ in throw DenialTestError.tombstoneFailed },
            currentAccountGeneration: { fixture.generation }
        )
        var readyCallbackReceived = false
        vm.onManagedBookReady = { if $0 == fixture.book.id { readyCallbackReceived = true } }
        await vm.refresh()
        await vm.delete(fixture.book)

        #expect(vm.deletionError?.contains("another file occupies") == true)
        #expect(Set(vm.books.map(\.id)) == Set([fixture.book.id, otherBook.id]))
        let deletionWitness = try #require(await witnessBox.value())
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(deletionWitness))
        #expect(try Data(contentsOf: fixture.destination) == competingBytes)
        #expect(try Data(contentsOf: stagedURL) == stagedBytes)
        let afterTargetRecovery = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(afterTargetRecovery.token == staged.token)
        #expect(afterTargetRecovery.preparedFileIdentifier == preparedFileIdentifier)
        #expect(afterTargetRecovery.phase == staged.phase)
        #expect(try await fixture.persistence.pendingMaterialization(
            bookID: otherBook.id, ownerID: fixture.ownerID
        ) == otherJob)
        let laterToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        await vm.applyImportEvent(BookImportEvent(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            token: laterToken, kind: .registered(fixture.book)
        ))
        await vm.applyImportEvent(BookImportEvent(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            token: laterToken, kind: .managedReady(fixture.book.id)
        ))
        #expect(!readyCallbackReceived)
    }

    @Test("failed deletion after prepared repair verifies and promotes the exact staged artifact")
    func failedDeletionAfterPreparedRepairRecoversExactStagedArtifact() async throws {
        let retirementSignal = BookRetirementSignal()
        let fixture = try await makeCoordinatorFixture(onBookRetirement: { await retirementSignal.signal() })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparedGate = SampleRepairRollbackGate()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            afterSampleRepairPrepared: { _ in await preparedGate.hold() }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }

        guard await preparedGate.waitUntilEntered() else {
            await preparedGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach the prepared boundary")
            return
        }
        let phaseBeforeDrain = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        let deletionTask = Task {
            await fixture.lifecycle.drainBookForDeletion(
                ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
            )
        }
        guard await retirementSignal.waitUntilSignaled() else {
            deletionTask.cancel()
            materialization.cancel()
            await preparedGate.release()
            _ = await deletionTask.value
            _ = await materialization.result
            Issue.record("failed deletion did not begin lifecycle retirement")
            return
        }
        materialization.cancel()
        await preparedGate.release()
        let witness = await deletionTask.value
        await #expect(throws: Error.self) { try await materialization.value }
        #expect(await preparedGate.didCancel())
        #expect(!(await preparedGate.didTimeOut()))

        let interrupted = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(interrupted.token == fixture.request.job.token)
        #expect(interrupted.sourceKind == .sampleRepair)
        #expect(interrupted.preparedFileIdentifier == phaseBeforeDrain.preparedFileIdentifier)
        #expect(interrupted.destinationFileIdentifier == phaseBeforeDrain.destinationFileIdentifier)
        #expect(interrupted.promotionRevision == phaseBeforeDrain.promotionRevision)
        #expect(interrupted.stagingRelativePath == phaseBeforeDrain.stagingRelativePath)
        #expect(interrupted.destinationRelativePath == phaseBeforeDrain.destinationRelativePath)
        #expect(interrupted.phase == .paused)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))

        let resumer = fixture.makeCoordinator()
        let recovery = BookImportRecovery(
            rootURL: fixture.root,
            bookStore: fixture.books,
            persistence: fixture.persistence,
            lifecycle: fixture.lifecycle,
            resumeRollbackRecovered: { book, token, lease in
                try await resumer.resumeRecovered(
                    book: book, token: token, provisionalRollbackLease: lease
                )
            },
            verifyReadyManagedSource: { book, _ in
                (try? await fixture.registry.managedSource(for: book)) != nil
            }
        )
        let coordinator = fixture.makeCoordinator()
        let result = await coordinator.restoreBookAfterFailedRetirement(
            book: fixture.book,
            witness: witness,
            expectedGeneration: fixture.generation,
            recoverStartedSampleRepair: { book, token, lease in
                await recovery.recoverBook(
                    book: book, expectedToken: token, rollbackLease: lease,
                    isCurrentIdentity: { true }
                )
            }
        )

        guard case let .ready(recoveredToken) = result else {
            Issue.record("staged failed-deletion rollback did not reach verified ready state: \(result)")
            return
        }
        #expect(recoveredToken != interrupted.token)
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.activatePromotionAttempt(interrupted.token))
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        let recovered = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(recovered.token == recoveredToken)
        #expect(recovered.phase == .ready)
        #expect((try await fixture.registry.managedSource(for: fixture.book)) != nil)
    }

    @Test("failed deletion after promotion rename verifies the final artifact before commit")
    func failedDeletionAfterRenameRecoversVerifiedFinalArtifact() async throws {
        let retirementSignal = BookRetirementSignal()
        let fixture = try await makeCoordinatorFixture(onBookRetirement: { await retirementSignal.signal() })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renameGate = SampleRepairRollbackGate()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            afterSampleRepairRename: { _ in await renameGate.hold() }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }

        guard await renameGate.waitUntilEntered() else {
            await renameGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach the post-rename boundary")
            return
        }
        let phaseBeforeDrain = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        let deletionTask = Task {
            await fixture.lifecycle.drainBookForDeletion(
                ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
            )
        }
        guard await retirementSignal.waitUntilSignaled() else {
            deletionTask.cancel()
            materialization.cancel()
            await renameGate.release()
            _ = await deletionTask.value
            _ = await materialization.result
            Issue.record("failed deletion did not begin lifecycle retirement")
            return
        }
        materialization.cancel()
        await renameGate.release()
        let witness = await deletionTask.value
        await #expect(throws: Error.self) { try await materialization.value }
        #expect(await renameGate.didCancel())
        #expect(!(await renameGate.didTimeOut()))

        let interrupted = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(interrupted.token == fixture.request.job.token)
        #expect(interrupted.preparedFileIdentifier == phaseBeforeDrain.preparedFileIdentifier)
        #expect(interrupted.destinationFileIdentifier == phaseBeforeDrain.destinationFileIdentifier)
        #expect(interrupted.promotionRevision == phaseBeforeDrain.promotionRevision)
        #expect(interrupted.stagingRelativePath == phaseBeforeDrain.stagingRelativePath)
        #expect(interrupted.destinationRelativePath == phaseBeforeDrain.destinationRelativePath)
        #expect(interrupted.phase == .paused)
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))

        let resumer = fixture.makeCoordinator()
        let recovery = BookImportRecovery(
            rootURL: fixture.root,
            bookStore: fixture.books,
            persistence: fixture.persistence,
            lifecycle: fixture.lifecycle,
            resumeRollbackRecovered: { book, token, lease in
                try await resumer.resumeRecovered(
                    book: book, token: token, provisionalRollbackLease: lease
                )
            },
            verifyReadyManagedSource: { book, _ in
                (try? await fixture.registry.managedSource(for: book)) != nil
            }
        )
        let result = await fixture.makeCoordinator().restoreBookAfterFailedRetirement(
            book: fixture.book,
            witness: witness,
            expectedGeneration: fixture.generation,
            recoverStartedSampleRepair: { book, token, lease in
                await recovery.recoverBook(
                    book: book, expectedToken: token, rollbackLease: lease,
                    isCurrentIdentity: { true }
                )
            }
        )

        guard case let .ready(recoveredToken) = result else {
            Issue.record("post-rename rollback did not verify and commit the final artifact: \(result)")
            return
        }
        #expect(recoveredToken != interrupted.token)
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.activatePromotionAttempt(interrupted.token))
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        let recovered = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(recovered.token == recoveredToken)
        #expect(recovered.phase == .ready)
        #expect((try await fixture.registry.managedSource(for: fixture.book)) != nil)
    }

    @MainActor
    @Test("committed recovery cancellation re-fences then retries the same deletion witness")
    func committedRecoveryCancellationCanRetrySameWitness() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let preparedGate = SampleRepairRollbackGate()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            afterSampleRepairPrepared: { _ in await preparedGate.hold() }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }
        guard await preparedGate.waitUntilEntered() else {
            materialization.cancel()
            await preparedGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach the prepared boundary")
            return
        }
        materialization.cancel()
        await preparedGate.release()
        await #expect(throws: Error.self) { try await materialization.value }
        let staged = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(staged.phase == .paused)
        #expect(staged.preparedFileIdentifier != nil)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(staged.stagingRelativePath)) == fixture.bytes)

        let commitGate = SampleRepairRollbackGate()
        let resumer = fixture.makeCoordinator()
        let recovery = BookImportRecovery(
            rootURL: fixture.root,
            bookStore: fixture.books,
            persistence: fixture.persistence,
            lifecycle: fixture.lifecycle,
            resumeRollbackRecovered: { book, token, lease in
                let fingerprint = try await resumer.resumeRecovered(
                    book: book, token: token, provisionalRollbackLease: lease
                )
                await commitGate.hold()
                return fingerprint
            },
            verifyReadyManagedSource: { book, _ in
                (try? await fixture.registry.managedSource(for: book)) != nil
            }
        )
        let coordinator = fixture.makeCoordinator()
        let firstAttempt = RollbackAttemptObservation()
        let markerProbe = LibraryDeletionMarkerProbe()
        let restore: @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async -> BookDeletionRollbackResult = {
            book, token, lease in
            await recovery.recoverBook(
                book: book, expectedToken: token, rollbackLease: lease,
                isCurrentIdentity: { true }
            )
        }
        let witnessBox = DeletionWitnessBox()
        let storage = BookFileStorage(rootURL: fixture.root, bookStore: fixture.books, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: fixture.books,
            currentUserId: { fixture.ownerID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { fixture.ownerID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in },
            beforeBookDeleted: { book in
                let witness = await fixture.lifecycle.drainBookForDeletion(
                    ownerID: book.userId, generation: fixture.generation, bookID: book.id
                )
                await witnessBox.set(witness)
                return witness
            },
            restoreBookAfterFailedRetirement: { book, witness in
                guard let witness else { return .refused }
                let interruptedAttempt = Task {
                    await coordinator.restoreBookAfterFailedRetirement(
                        book: book, witness: witness, expectedGeneration: fixture.generation,
                        recoverStartedSampleRepair: restore
                    )
                }
                guard await commitGate.waitUntilEntered() else {
                    interruptedAttempt.cancel()
                    await commitGate.release()
                    let first = await interruptedAttempt.value
                    await firstAttempt.record(result: first, readyJob: nil,
                        witnessIsCurrent: false, managedSourceReadable: false,
                        readyEventAcceptedWhileFenced: true)
                    return .refused
                }

                interruptedAttempt.cancel()
                await commitGate.release()
                let first = await interruptedAttempt.value
                let committed = try? await fixture.persistence.pendingMaterialization(
                    bookID: book.id, ownerID: book.userId
                )
                let managedSourceReadable = (try? await fixture.registry.managedSource(for: book)) != nil
                if let committed {
                    await markerProbe.sendReadyEvents(book: book, token: committed.token)
                }
                await firstAttempt.record(
                    result: first,
                    readyJob: committed,
                    witnessIsCurrent: fixture.lifecycle.isCurrentDeletionRetirementWitness(witness),
                    managedSourceReadable: managedSourceReadable,
                    readyEventAcceptedWhileFenced: await markerProbe.readyEventWasAccepted()
                )
                return await coordinator.restoreBookAfterFailedRetirement(
                    book: book, witness: witness, expectedGeneration: fixture.generation,
                    recoverStartedSampleRepair: restore
                )
            },
            onBookDeleted: { _ in throw DenialTestError.tombstoneFailed },
            currentAccountGeneration: { fixture.generation }
        )
        vm.onManagedBookReady = { _ in markerProbe.markReadyEvent() }
        await markerProbe.attach(vm)
        await vm.refresh()
        await vm.delete(fixture.book)

        let witness = try #require(await witnessBox.value())
        let firstResult = try #require(await firstAttempt.result())
        guard case .refused = firstResult.0,
              let committedJob = firstResult.1,
              committedJob.phase == .ready,
              committedJob.token != staged.token,
              firstResult.2,
              !firstResult.3,
              !firstResult.4 else {
            Issue.record("cancelled post-commit recovery did not retain the witness and committed ready token")
            return
        }
        let finalJob = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(finalJob.phase == .ready)
        let finalToken = finalJob.token
        #expect(finalToken == committedJob.token)
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        #expect((try await fixture.registry.managedSource(for: fixture.book)) != nil)

        await markerProbe.sendReadyEvents(book: fixture.book, token: finalToken)
        #expect(await markerProbe.readyEventWasAccepted())
    }

    @Test("cancellation after recovery adoption preserves its successor for exact retry")
    func adoptedRecoveryCancellationRetriesWithoutRotatingToken() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let preparedGate = SampleRepairRollbackGate()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root, lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry, persistence: fixture.persistence,
            bookStore: fixture.books, currentGeneration: { fixture.generation },
            afterSampleRepairPrepared: { _ in await preparedGate.hold() }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }
        guard await preparedGate.waitUntilEntered() else {
            materialization.cancel()
            await preparedGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach the prepared boundary")
            return
        }
        materialization.cancel()
        await preparedGate.release()
        await #expect(throws: Error.self) { try await materialization.value }

        let witness = await fixture.lifecycle.drainBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        let adoptionGate = RecoveryAdoptionGate()
        let gatedPersistence = RecoveryAdoptionGatePersistence(
            base: fixture.persistence, gate: adoptionGate
        )
        let resumer = fixture.makeCoordinator()
        let recovery = BookImportRecovery(
            rootURL: fixture.root, bookStore: fixture.books,
            persistence: gatedPersistence, lifecycle: fixture.lifecycle,
            resumeRollbackRecovered: { book, token, lease in
                try await resumer.resumeRecovered(book: book, token: token, provisionalRollbackLease: lease)
            },
            verifyReadyManagedSource: { book, _ in
                (try? await fixture.registry.managedSource(for: book)) != nil
            }
        )
        let coordinator = fixture.makeCoordinator()
        let leaseObservation = RollbackLeaseObservation()
        let recover: @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async -> BookDeletionRollbackResult = {
            book, token, lease in
            await leaseObservation.record(lease)
            return await recovery.recoverBook(
                book: book, expectedToken: token, rollbackLease: lease,
                isCurrentIdentity: { true }
            )
        }
        let firstAttempt = Task {
            await coordinator.restoreBookAfterFailedRetirement(
                book: fixture.book, witness: witness, expectedGeneration: fixture.generation,
                recoverStartedSampleRepair: recover
            )
        }
        guard await adoptionGate.waitUntilEntered() else {
            firstAttempt.cancel()
            await adoptionGate.release()
            _ = await firstAttempt.value
            Issue.record("recovery did not reach its successful adoption-return boundary")
            return
        }
        firstAttempt.cancel()
        await adoptionGate.release()
        let firstResult = await firstAttempt.value
        let adopted = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        guard case .refused = firstResult else {
            Issue.record("cancelled recovery unexpectedly finalized its provisional lease")
            return
        }
        #expect(adopted.phase == .paused)
        #expect(adopted.token != fixture.request.job.token)
        #expect(adopted.preparedFileIdentifier != nil)
        #expect(adopted.stagingRelativePath == fixture.request.job.stagingRelativePath)
        #expect(adopted.destinationRelativePath == fixture.book.fileURL)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        let firstLease = try #require(await leaseObservation.value())
        #expect(!fixture.lifecycle.isCurrentProvisionalDeletionRollbackLease(firstLease))

        let retry = await coordinator.restoreBookAfterFailedRetirement(
            book: fixture.book, witness: witness, expectedGeneration: fixture.generation,
            recoverStartedSampleRepair: recover
        )
        guard case let .ready(readyToken) = retry else {
            Issue.record("same-witness retry did not finalize the adopted successor: \(retry)")
            return
        }
        #expect(readyToken != fixture.request.job.token)
        let ready = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(ready.token == readyToken)
        #expect(ready.token != fixture.request.job.token)
        #expect(ready.phase == .ready)
        #expect(await adoptionGate.successfulCASCount() <= 2)
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        #expect((try await fixture.registry.managedSource(for: fixture.book)) != nil)
    }

    @Test("quarantine cancellation retains its exact successor for same-witness parking and fresh repair")
    func quarantineCancellationRetainsSuccessorForRetry() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparedGate = SampleRepairRollbackGate()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root, lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry, persistence: fixture.persistence,
            bookStore: fixture.books, currentGeneration: { fixture.generation },
            afterSampleRepairPrepared: { _ in await preparedGate.hold() }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }
        guard await preparedGate.waitUntilEntered() else {
            materialization.cancel()
            await preparedGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach prepared state")
            return
        }
        materialization.cancel()
        await preparedGate.release()
        await #expect(throws: Error.self) { try await materialization.value }
        let staged = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        let stagedURL = fixture.root.appendingPathComponent(staged.stagingRelativePath)
        try Data("invalid replaced staged bytes".utf8).write(to: stagedURL)
        let witness = await fixture.lifecycle.drainBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )

        let quarantineGate = RecoveryAdoptionGate()
        let gatedPersistence = RecoveryAdoptionGatePersistence(
            base: fixture.persistence, gate: RecoveryAdoptionGate(), quarantineGate: quarantineGate
        )
        let recovery = BookImportRecovery(
            rootURL: fixture.root, bookStore: fixture.books,
            persistence: gatedPersistence, lifecycle: fixture.lifecycle
        )
        let coordinator = fixture.makeCoordinator()
        let recover: @Sendable (Book, BookMaterializationToken, BookImportProvisionalRollbackLease) async -> BookDeletionRollbackResult = {
            book, token, lease in
            return await recovery.recoverBook(
                book: book, expectedToken: token, rollbackLease: lease,
                isCurrentIdentity: { true }
            )
        }
        let interrupted = Task {
            await coordinator.restoreBookAfterFailedRetirement(
                book: fixture.book, witness: witness, expectedGeneration: fixture.generation,
                recoverStartedSampleRepair: recover
            )
        }
        guard await quarantineGate.waitUntilEntered() else {
            interrupted.cancel()
            await quarantineGate.release()
            _ = await interrupted.value
            Issue.record("invalid staged repair did not reach successful quarantine CAS")
            return
        }
        interrupted.cancel()
        await quarantineGate.release()
        let interruptedResult = await interrupted.value
        #expect(!(await quarantineGate.didTimeOut()))
        #expect(await quarantineGate.successfulCASCount() == 1)
        let quarantined = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        guard case .refused = interruptedResult else {
            Issue.record("cancelled quarantine unexpectedly finalized the deletion rollback")
            return
        }
        #expect(quarantined.phase == .paused)
        #expect(quarantined.token != staged.token)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.activatePromotionAttempt(staged.token))

        let parkedResult = await coordinator.restoreBookAfterFailedRetirement(
            book: fixture.book, witness: witness, expectedGeneration: fixture.generation,
            recoverStartedSampleRepair: recover
        )
        #expect(parkedResult == .retryablePaused(quarantined.token))
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.activatePromotionAttempt(staged.token))

        let freshToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let freshVersion = try #require(try CoordinatedSourceProbe.version(
            at: fixture.sourceURL, revision: UUID()
        ))
        let freshJob = PendingBookMaterialization(
            token: freshToken, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: freshVersion,
            expectedSHA256: fixture.fingerprint.sha256,
            expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(freshToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        let freshRequest = SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fixture.fingerprint,
            canonicalManagedURL: fixture.destination, expectedManagedFileVersion: nil,
            expectedPriorPendingToken: quarantined.token, job: freshJob
        )
        _ = try await fixture.makeCoordinator().materializeReservedSampleRepair(
            request: freshRequest, sourceURL: fixture.sourceURL
        )
        let ready = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(ready.token == freshToken)
        #expect(ready.phase == .ready)
        #expect(!fixture.lifecycle.activatePromotionAttempt(staged.token))
        #expect(!fixture.lifecycle.activatePromotionAttempt(quarantined.token))
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
    }

    @Test("nil-token failed-deletion witnesses preserve ready owned and sample-repair books")
    func nilTokenReadyRollbackKeepsBothSourceKinds() async throws {
        for expectsSampleRepair in [false, true] {
            let fixture = try await makeCoordinatorFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let readyBook: Book
            let readyToken: BookMaterializationToken

            if expectsSampleRepair {
                _ = try await fixture.makeCoordinator().materializeReservedSampleRepair(
                    request: fixture.request, sourceURL: fixture.sourceURL
                )
                readyBook = fixture.book
                readyToken = fixture.request.job.token
            } else {
                readyBook = Book(
                    userId: fixture.ownerID, title: "Ready owned import",
                    formatType: .epub, fileURL: "Books/ready-owned-\(UUID()).epub"
                )
                let token = BookMaterializationToken(
                    ownerID: fixture.ownerID, accountGeneration: fixture.generation,
                    bookID: readyBook.id, attemptID: UUID()
                )
                readyToken = token
                let sourceRelativePath = "Imports/\(token.attemptID.uuidString)/source.epub"
                let sourceURL = fixture.root.appendingPathComponent(sourceRelativePath)
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fixture.bytes.write(to: sourceURL)
                let version = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
                let job = PendingBookMaterialization(
                    token: token, sourceKind: .ownedStaging, sourceBookmark: nil,
                    ownedSourceRelativePath: sourceRelativePath, sourceVersion: version,
                    expectedSHA256: fixture.fingerprint.sha256,
                    expectedByteCount: Int64(fixture.bytes.count),
                    stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
                    destinationRelativePath: readyBook.fileURL, phase: .registered
                )
                let admission = try #require(fixture.lifecycle.admitBookMaterialization(token))
                let registration = try await fixture.persistence.reserveRegistration(
                    book: readyBook, job: job, candidate: nil
                )
                #expect(registration.token == token)
                admission.release()
                _ = try await fixture.makeCoordinator().materialize(
                    book: readyBook, token: token, sourceURL: sourceURL
                )
            }

            let persistedReady = try #require(await fixture.persistence.pendingMaterialization(
                bookID: readyBook.id, ownerID: readyBook.userId
            ))
            #expect(persistedReady.phase == .ready)
            if expectsSampleRepair {
                guard case .sampleRepair = persistedReady.sourceKind else {
                    Issue.record("sample repair fixture did not persist a sample-repair ready job")
                    return
                }
            } else {
                guard case .ownedStaging = persistedReady.sourceKind else {
                    Issue.record("owned import fixture did not persist an owned-staging ready job")
                    return
                }
            }
            #expect(persistedReady.token == readyToken)

            // A relaunch has durable ready state but no in-memory attempt token.
            let relaunchedLifecycle = BookImportLifecycle(
                sourceRegistry: fixture.registry,
                currentAccountGeneration: { fixture.generation }
            )
            let witness = await relaunchedLifecycle.drainBookForDeletion(
                ownerID: readyBook.userId, generation: fixture.generation, bookID: readyBook.id
            )
            #expect(witness.retiredToken == nil)
            let relaunchedCoordinator = BookMaterializationCoordinator(
                rootURL: fixture.root, lifecycle: relaunchedLifecycle,
                sourceRegistry: fixture.registry, persistence: fixture.persistence,
                bookStore: fixture.books, currentGeneration: { fixture.generation }
            )
            let restored = await relaunchedCoordinator.restoreBookAfterFailedRetirement(
                book: readyBook, witness: witness, expectedGeneration: fixture.generation,
                recoverStartedSampleRepair: { _, _, _ in .refused }
            )
            #expect(restored == .existingReady)
            #expect(!relaunchedLifecycle.isCurrentDeletionRetirementWitness(witness))
            let afterRollback = try #require(await fixture.persistence.pendingMaterialization(
                bookID: readyBook.id, ownerID: readyBook.userId
            ))
            #expect(afterRollback == persistedReady)
            #expect((try await fixture.registry.managedSource(for: readyBook)) != nil)
            #expect(try Data(contentsOf: fixture.root.appendingPathComponent(readyBook.fileURL)) == fixture.bytes)
        }
    }

    @Test("deletion during unprepared copying parks the exact attempt for a fresh retry")
    func failedDeletionDuringUnpreparedCopyParksAndRetriesFreshToken() async throws {
        let retirementSignal = BookRetirementSignal()
        let fixture = try await makeCoordinatorFixture(onBookRetirement: { await retirementSignal.signal() })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let copyGate = SampleRepairRollbackGate()
        let copier = CoordinatedBookCopier()
        let materializer = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            copySelectedSource: { _, source, stagingURL, sha256, byteCount, version in
                await copyGate.hold()
                try Task.checkCancellation()
                return try await copier.copy(
                    source: source, to: stagingURL, expectedSHA256: sha256,
                    expectedByteCount: byteCount, sourceVersion: version
                )
            }
        )
        let materialization = Task {
            try await materializer.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }

        guard await copyGate.waitUntilEntered() else {
            await copyGate.release()
            _ = await materialization.result
            Issue.record("sample repair did not reach the copy boundary")
            return
        }
        let copying = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(copying.phase == .copying)
        #expect(copying.preparedFileIdentifier == nil)
        #expect(copying.destinationFileIdentifier == nil)
        #expect(copying.promotionRevision == nil)
        let phaseBeforeDrain = copying

        let deletionTask = Task {
            await fixture.lifecycle.drainBookForDeletion(
                ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
            )
        }
        guard await retirementSignal.waitUntilSignaled() else {
            deletionTask.cancel()
            materialization.cancel()
            await copyGate.release()
            _ = await deletionTask.value
            _ = await materialization.result
            Issue.record("failed deletion did not begin lifecycle retirement")
            return
        }
        materialization.cancel()
        await copyGate.release()
        let witness = await deletionTask.value
        await #expect(throws: Error.self) { try await materialization.value }
        #expect(await copyGate.didCancel())
        #expect(!(await copyGate.didTimeOut()))

        let rollback = await fixture.makeCoordinator().restoreBookAfterFailedRetirement(
            book: fixture.book, witness: witness, expectedGeneration: fixture.generation,
            recoverStartedSampleRepair: { _, _, _ in .refused }
        )
        #expect(rollback == .retryablePaused(copying.token))
        #expect(!fixture.lifecycle.isCurrentDeletionRetirementWitness(witness))
        #expect(!fixture.lifecycle.activatePromotionAttempt(copying.token))
        let paused = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(paused.token == copying.token)
        #expect(paused.phase == .paused)
        #expect(paused.preparedFileIdentifier == phaseBeforeDrain.preparedFileIdentifier)
        #expect(paused.destinationFileIdentifier == phaseBeforeDrain.destinationFileIdentifier)
        #expect(paused.promotionRevision == phaseBeforeDrain.promotionRevision)
        #expect(paused.stagingRelativePath == phaseBeforeDrain.stagingRelativePath)
        #expect(paused.destinationRelativePath == phaseBeforeDrain.destinationRelativePath)
        #expect(paused.preparedFileIdentifier == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(paused.stagingRelativePath).path
        ))

        let freshToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let freshVersion = try #require(try CoordinatedSourceProbe.version(
            at: fixture.sourceURL, revision: UUID()
        ))
        let freshJob = PendingBookMaterialization(
            token: freshToken, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: freshVersion,
            expectedSHA256: fixture.fingerprint.sha256,
            expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(freshToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        let freshRequest = SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fixture.fingerprint,
            canonicalManagedURL: fixture.destination, expectedManagedFileVersion: nil,
            expectedPriorPendingToken: paused.token, job: freshJob
        )
        guard case .repaired = try await fixture.makeCoordinator().materializeReservedSampleRepair(
            request: freshRequest, sourceURL: fixture.sourceURL
        ) else {
            Issue.record("fresh sample-repair token did not complete")
            return
        }
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        let ready = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(ready.token == freshToken)
        #expect(ready.phase == .ready)
    }

    @Test("targeted sample recovery refuses a lease invalidated by a newer deletion")
    func targetedRecoveryRefusesStaleDeletionLease() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstWitness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        let oldLease = try #require(fixture.lifecycle.beginProvisionalDeletionRollback(witness: firstWitness))
        let newerWitness = fixture.lifecycle.retireBookForDeletion(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        )
        let recovery = BookImportRecovery(
            rootURL: fixture.root,
            bookStore: fixture.books,
            persistence: fixture.persistence,
            lifecycle: fixture.lifecycle
        )

        let result = await recovery.recoverBook(
            book: fixture.book,
            expectedToken: fixture.request.job.token,
            rollbackLease: oldLease,
            isCurrentIdentity: { true }
        )

        #expect(result == .refused)
        #expect(fixture.lifecycle.isCurrentDeletionRetirementWitness(newerWitness))
        #expect(!fixture.lifecycle.isCurrentProvisionalDeletionRollbackLease(oldLease))
        #expect(fixture.lifecycle.claimBookRecovery(
            ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
        ) == nil)
    }

    @Test("reservation denied by deletion is parked and can be retried with a fresh token")
    func reservationDenialParksExactTokenAndAllowsRetry() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let witnessBox = DeletionWitnessBox()
        let denyingCoordinator = BookMaterializationCoordinator(
            rootURL: fixture.root,
            lifecycle: fixture.lifecycle,
            sourceRegistry: fixture.registry,
            persistence: fixture.persistence,
            bookStore: fixture.books,
            currentGeneration: { fixture.generation },
            afterSampleRepairReservation: { _ in
                let witness = fixture.lifecycle.retireBookForDeletion(
                    ownerID: fixture.ownerID, generation: fixture.generation, bookID: fixture.book.id
                )
                await witnessBox.set(witness)
            }
        )

        await #expect(throws: Error.self) {
            _ = try await denyingCoordinator.materializeReservedSampleRepair(
                request: fixture.request, sourceURL: fixture.sourceURL
            )
        }
        let parked = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(parked.token == fixture.request.job.token)
        #expect(parked.sourceKind == .sampleRepair)
        #expect(parked.phase == .paused)
        let witness = try #require(await witnessBox.value())
        #expect(fixture.lifecycle.restoreBookFenceAfterFailedRetirement(
            witness: witness, parkedRepairToken: parked.token
        ))

        let retryToken = BookMaterializationToken(
            ownerID: fixture.ownerID, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: fixture.sourceURL, revision: UUID()))
        let retryJob = PendingBookMaterialization(
            token: retryToken, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: fixture.fingerprint.sha256,
            expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(retryToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        let retryRequest = SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fixture.fingerprint,
            canonicalManagedURL: fixture.destination, expectedManagedFileVersion: nil,
            expectedPriorPendingToken: parked.token, job: retryJob
        )
        guard case .repaired(let fingerprint) = try await fixture.makeCoordinator().materializeReservedSampleRepair(
            request: retryRequest, sourceURL: fixture.sourceURL
        ) else {
            Issue.record("fresh exact retry did not repair the sample")
            return
        }
        #expect(fingerprint.sha256 == fixture.fingerprint.sha256)
        #expect(try Data(contentsOf: fixture.destination) == fixture.bytes)
        let completed = try #require(await fixture.persistence.pendingMaterialization(
            bookID: fixture.book.id, ownerID: fixture.ownerID
        ))
        #expect(completed.token == retryToken)
        #expect(completed.phase == .ready)
    }

    @MainActor
    @Test("failed tombstone rollback uses its witness and permits a later registration and readiness event")
    func failedTombstoneRollbackClearsLocalDeletionMarker() async throws {
        let ownerID = UUID()
        let generation: UInt64 = 44
        let book = Book(userId: ownerID, title: "Rollback sample", formatType: .epub, fileURL: "Books/rollback.epub")
        let store = InMemoryBookStore(initial: [book])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("denial-vm-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftDataBookImportPersistence(
            dbStore: try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:")), managedFileRootURL: root
        )
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { ownerID },
            managedURL: { _ in nil }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let parkedToken = BookMaterializationToken(
            ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID()
        )
        let witnessBox = DeletionWitnessBox()
        let restoreMatchedWitness = BoolObservation()
        let cleanup = BoolObservation()
        var readyCallbackReceived = false
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { ownerID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { ownerID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { _ in await cleanup.set(true) },
            beforeBookDeleted: { requestedBook in
                let witness = await lifecycle.drainBookForDeletion(
                    ownerID: requestedBook.userId, generation: generation, bookID: requestedBook.id
                )
                await witnessBox.set(witness)
                return witness
            },
            restoreBookAfterFailedRetirement: { _, candidate in
                let exactWitness = await witnessBox.value()
                let matches = candidate != nil && candidate == exactWitness
                await restoreMatchedWitness.set(matches)
                guard let candidate, matches else { return .refused }
                let restored = lifecycle.restoreBookFenceAfterFailedRetirement(
                    witness: candidate, parkedRepairToken: parkedToken
                )
                return restored ? .retryablePaused(parkedToken) : .refused
            },
            onBookDeleted: { _ in throw DenialTestError.tombstoneFailed },
            currentAccountGeneration: { generation }
        )
        vm.onManagedBookReady = { id in
            if id == book.id { readyCallbackReceived = true }
        }
        await vm.refresh()
        await vm.delete(book)

        #expect(await restoreMatchedWitness.value() == true)
        #expect(await cleanup.value() == false)
        #expect(vm.deletionError != nil)
        let registrationToken = BookMaterializationToken(
            ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID()
        )
        await vm.applyImportEvent(BookImportEvent(
            ownerID: ownerID, accountGeneration: generation, token: registrationToken, kind: .registered(book)
        ))
        await vm.applyImportEvent(BookImportEvent(
            ownerID: ownerID, accountGeneration: generation, token: registrationToken, kind: .managedReady(book.id)
        ))
        #expect(vm.books.map(\.id) == [book.id])
        #expect(readyCallbackReceived)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sample-repair-denial-\(UUID().uuidString)", isDirectory: true
        )
        let ownerID = UUID()
        let generation: UInt64 = 31
        let book = Book(userId: ownerID, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { ownerID },
            managedURL: { _ in nil }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let retiredToken = BookMaterializationToken(
            ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID()
        )
        let parkedToken = BookMaterializationToken(
            ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID()
        )
        return Fixture(ownerID: ownerID, generation: generation, book: book,
                       lifecycle: lifecycle, retiredToken: retiredToken, parkedToken: parkedToken)
    }

    private func makeCoordinatorFixture(
        onBookRetirement: @escaping @Sendable () async -> Void = {}
    ) async throws -> CoordinatorFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sample-repair-denial-coordinator-\(UUID().uuidString)", isDirectory: true
        )
        let sourceURL = root.appendingPathComponent("source/sample.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: sourceURL, withCover: false)
        let bytes = try Data(contentsOf: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 52
        let book = Book(userId: ownerID, title: "Repairable sample", formatType: .epub, fileURL: "Books/repairable.epub")
        let destination = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let revision = UUID()
        let managedVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: destination, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(
            bookID: book.id, ownerID: ownerID, sha256: digest, version: managedVersion
        )
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(
            bookID: book.id, ownerID: ownerID, generation: generation,
            contentRevision: revision, tombstoned: false
        )
        #expect(try await persistence.cacheManagedFingerprint(
            fingerprint, expectedGeneration: generation,
            expectedRelativePath: book.fileURL, expectedVersion: managedVersion
        ))
        try FileManager.default.removeItem(at: destination)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation }, currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(
            sourceRegistry: registry, currentAccountGeneration: { generation },
            cancelBookWork: { _, _, _ in Task { await onBookRetirement() } }
        )
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
        let token = BookMaterializationToken(
            ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID()
        )
        let job = PendingBookMaterialization(
            token: token, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .registered
        )
        let request = SampleRepairReservationRequest(
            expectedBook: book, expectedFingerprint: fingerprint, canonicalManagedURL: destination,
            expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
        )
        return CoordinatorFixture(
            root: root, sourceURL: sourceURL, bytes: bytes, ownerID: ownerID, generation: generation,
            book: book, destination: destination, fingerprint: fingerprint, books: books,
            persistence: persistence, registry: registry, lifecycle: lifecycle, request: request
        )
    }
}

private struct Fixture {
    let ownerID: UUID
    let generation: UInt64
    let book: Book
    let lifecycle: BookImportLifecycle
    let retiredToken: BookMaterializationToken
    let parkedToken: BookMaterializationToken
}

private struct CoordinatorFixture {
    let root: URL
    let sourceURL: URL
    let bytes: Data
    let ownerID: UserID
    let generation: UInt64
    let book: Book
    let destination: URL
    let fingerprint: BookFileFingerprint
    let books: SwiftDataBookStore
    let persistence: SwiftDataBookImportPersistence
    let registry: BookSourceRegistry
    let lifecycle: BookImportLifecycle
    let request: SampleRepairReservationRequest

    func makeCoordinator() -> BookMaterializationCoordinator {
        BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry,
            persistence: persistence, bookStore: books, currentGeneration: { generation }
        )
    }
}

private actor DeletionWitnessBox {
    private var stored: BookDeletionRetirementWitness?
    func set(_ witness: BookDeletionRetirementWitness) { stored = witness }
    func value() -> BookDeletionRetirementWitness? { stored }
}

private actor BookRetirementSignal {
    private var signaled = false

    func signal() { signaled = true }

    func waitUntilSignaled() async -> Bool {
        for _ in 0..<800 {
            if signaled { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return signaled
    }
}

private actor RollbackLeaseObservation {
    private var stored: BookImportProvisionalRollbackLease?
    func record(_ lease: BookImportProvisionalRollbackLease) { stored = lease }
    func value() -> BookImportProvisionalRollbackLease? { stored }
}

private actor RecoveryAdoptionGate {
    private var entered = false
    private var released = false
    private var timedOut = false
    private var casCount = 0

    func holdAfterSuccessfulCAS() async {
        casCount += 1
        entered = true
        for _ in 0..<800 {
            if released { return }
            await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        timedOut = true
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<800 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() { released = true }
    func didTimeOut() -> Bool { timedOut }
    func successfulCASCount() -> Int { casCount }
}

private struct RecoveryAdoptionGatePersistence: BookImportPersistence {
    let base: any BookImportPersistence
    let gate: RecoveryAdoptionGate
    var quarantineGate: RecoveryAdoptionGate? = nil

    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration {
        try await base.reserveRegistration(book: book, job: job, candidate: candidate)
    }
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? {
        try await base.joinOrRetryPending(ownerID: ownerID, sha256: sha256, newSource: newSource, retiredAttempt: retiredAttempt)
    }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool {
        try await base.transition(token: token, from: from, to: to)
    }
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool {
        try await base.commitManaged(token: token, fingerprint: fingerprint)
    }
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool {
        try await base.patchCover(bookID: bookID, token: token, relativePath: relativePath)
    }
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? {
        let successor = try await base.adoptRecovery(
            expectedToken: expectedToken, currentOwnerID: currentOwnerID,
            currentGeneration: currentGeneration, newAttemptID: newAttemptID,
            verifiedArtifacts: verifiedArtifacts
        )
        if successor != nil { await gate.holdAfterSuccessfulCAS() }
        return successor
    }
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? {
        let successor = try await base.quarantineRecovery(
            expectedToken: expectedToken, currentOwnerID: currentOwnerID,
            currentGeneration: currentGeneration, newAttemptID: newAttemptID
        )
        if successor != nil, let quarantineGate {
            await quarantineGate.holdAfterSuccessfulCAS()
        }
        return successor
    }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        try await base.fingerprint(bookID: bookID, ownerID: ownerID)
    }
    func sampleRepairFingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        try await base.sampleRepairFingerprint(bookID: bookID, ownerID: ownerID)
    }
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        try await base.pendingMaterialization(bookID: bookID, ownerID: ownerID)
    }
    func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit? {
        try await base.readingPermit(bookID: bookID, ownerID: ownerID, generation: generation)
    }
    func readingPermit(forManagedFingerprint fingerprint: BookFileFingerprint, expectedRelativePath: String, generation: UInt64) async throws -> BookReadingPermit? {
        try await base.readingPermit(
            forManagedFingerprint: fingerprint, expectedRelativePath: expectedRelativePath,
            generation: generation
        )
    }
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {
        try await base.setAccountAuthorization(ownerID: ownerID, generation: generation)
    }
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {
        try await base.setBookReadingAuthorization(
            bookID: bookID, ownerID: ownerID, generation: generation,
            contentRevision: contentRevision, tombstoned: tombstoned
        )
    }

    // Delegates every required operation to the real persistence; only recovery CAS is gated.
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { try await base.cacheManagedFingerprint(fingerprint, expectedGeneration: expectedGeneration, expectedRelativePath: expectedRelativePath, expectedVersion: expectedVersion) }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { try await base.reauthorizeReadyManagedSource(bookID: bookID, ownerID: ownerID, generation: generation, fingerprint: fingerprint) }
    func parkSampleRepair(book: Book, token: BookMaterializationToken) async -> SampleRepairParkingOutcome { await base.parkSampleRepair(book: book, token: token) }
    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?, excludedBookIDs: Set<BookID>) async throws -> BookRegistration { try await base.reserveRegistration(book: book, job: job, candidate: candidate, excludedBookIDs: excludedBookIDs) }
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool { try await base.discardUnpublishedRegistration(token: token) }
    func retryExpectation(bookID: BookID, ownerID: UserID, accountPermit: AccountMutationPermit) async throws -> BookImportRetryExpectation? { try await base.retryExpectation(bookID: bookID, ownerID: ownerID, accountPermit: accountPermit) }
    func retryPendingMaterialization(expected: BookImportRetryExpectation, accountPermit: AccountMutationPermit, newSource: PendingBookMaterialization, verifiedSourceSHA256: String, verifiedSourceByteCount: Int64, verifiedSourceVersion: ManagedFileVersion, retiredAttempt: RetiredBookMaterializationAttempt) async throws -> BookRegistration? { try await base.retryPendingMaterialization(expected: expected, accountPermit: accountPermit, newSource: newSource, verifiedSourceSHA256: verifiedSourceSHA256, verifiedSourceByteCount: verifiedSourceByteCount, verifiedSourceVersion: verifiedSourceVersion, retiredAttempt: retiredAttempt) }
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool { try await base.recordPrepared(token: token, artifacts: artifacts) }
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { try await base.claimPromotion(token: token, preparedFileIdentifier: preparedFileIdentifier, promotionRevision: promotionRevision) }
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool { try await base.recordPromoted(token: token, preparedFileIdentifier: preparedFileIdentifier, destinationFileIdentifier: destinationFileIdentifier, promotionRevision: promotionRevision) }
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? { try await base.reauthorizeWaitingRecovery(expectedToken: expectedToken, currentOwnerID: currentOwnerID, currentGeneration: currentGeneration) }
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool { try await base.refreshSourceBookmark(token: token, refreshedData: refreshedData) }
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? { try await base.pendingMaterializationForDeletionCleanup(bookID: bookID, ownerID: ownerID) }
    func pendingMaterializationsForDeletionCleanup(ownerID: UserID) async throws -> [PendingBookMaterialization] { try await base.pendingMaterializationsForDeletionCleanup(ownerID: ownerID) }
    func isBookPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool { try await base.isBookPermanentlyDeleted(bookID: bookID, ownerID: ownerID) }
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool { try await base.deletePendingMaterializationForDeletionCleanup(bookID: bookID, ownerID: ownerID, expectedToken: expectedToken) }
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? { try await base.pendingMaterializationForRecovery(bookID: bookID, ownerID: ownerID, currentGeneration: currentGeneration) }
    func recordServerAcceptance(permit: BookReadingPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { try await base.recordServerAcceptance(permit: permit, expectedFingerprint: expectedFingerprint, acceptance: acceptance) }
    func recordServerAcceptance(accountPermit: AccountMutationPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { try await base.recordServerAcceptance(accountPermit: accountPermit, expectedFingerprint: expectedFingerprint, acceptance: acceptance) }
}

private actor SampleRepairRollbackGate {
    private var entered = false
    private var released = false
    private var cancelled = false
    private var timedOut = false

    func hold() async {
        entered = true
        for _ in 0..<800 {
            if Task.isCancelled {
                cancelled = true
                return
            }
            if released { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        timedOut = true
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<800 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() { released = true }
    func didCancel() -> Bool { cancelled }
    func didTimeOut() -> Bool { timedOut }
}

private actor RollbackAttemptObservation {
    private var stored: (
        BookDeletionRollbackResult, PendingBookMaterialization?, Bool, Bool, Bool
    )?

    func record(
        result: BookDeletionRollbackResult,
        readyJob: PendingBookMaterialization?,
        witnessIsCurrent: Bool,
        managedSourceReadable: Bool,
        readyEventAcceptedWhileFenced: Bool
    ) {
        stored = (result, readyJob, witnessIsCurrent, managedSourceReadable, readyEventAcceptedWhileFenced)
    }

    func result() -> (
        BookDeletionRollbackResult, PendingBookMaterialization?, Bool, Bool, Bool
    )? {
        stored
    }
}

@MainActor
private final class LibraryDeletionMarkerProbe {
    private var viewModel: LibraryViewModel?
    private var didReceiveReadyEvent = false

    func attach(_ viewModel: LibraryViewModel) { self.viewModel = viewModel }
    func markReadyEvent() { didReceiveReadyEvent = true }
    func readyEventWasAccepted() -> Bool { didReceiveReadyEvent }

    func sendReadyEvents(book: Book, token: BookMaterializationToken) async {
        await viewModel?.applyImportEvent(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .registered(book)
        ))
        await viewModel?.applyImportEvent(BookImportEvent(
            ownerID: token.ownerID, accountGeneration: token.accountGeneration,
            token: token, kind: .managedReady(book.id)
        ))
    }
}

private actor BoolObservation {
    private var stored = false
    func set(_ value: Bool) { stored = value }
    func value() -> Bool { stored }
}

private enum DenialTestError: Error {
    case tombstoneFailed
    case gateTimedOut
}

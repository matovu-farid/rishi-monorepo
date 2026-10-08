@testable import rishi
import Foundation
import Testing

@Suite("FirstBookSampleCoordinator")
@MainActor
struct FirstBookSampleCoordinatorTests {
    @Test("sample is handed off only after recovery, install, lease, readiness, and dismissal")
    func successfulHandoffIsOrderedAndOwnsLeaseUntilCompletion() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: true
        )

        await coordinator.selectSample()
        #expect(coordinator.state == .ready(book))
        #expect(await effects.events == ["recovery", "install", "lease", "readiness", "dismiss"])
        #expect(await effects.leaseReleaseCount == 0)

        await coordinator.completeDismissal()
        await coordinator.completeDismissal()
        await effects.waitForLeaseRelease()

        let completedEvents = await effects.events.filter { $0 != "leaseReleased" }
        #expect(completedEvents == [
            "recovery", "install", "lease", "readiness", "dismiss",
            "tour", "open", "seen", "clearRecovery"
        ])
        #expect(await effects.leaseReleaseCount == 1)
        #expect(await effects.events.filter { $0 == "open" }.count == 1)
        #expect(await effects.events.filter { $0 == "seen" }.count == 1)
    }

    @Test("a failed readiness check keeps recovery and retrying starts a new attempt")
    func readinessFailureCanRetry() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        await effects.failNextReadiness()
        let coordinator = makeCoordinator(owner: owner, book: book, effects: effects, openResult: true)

        await coordinator.selectSample()
        #expect(coordinator.state == .failed)
        await effects.waitForLeaseRelease()
        #expect(await effects.events == ["recovery", "install", "lease", "readiness", "leaseReleased"])

        await coordinator.retry()
        #expect(coordinator.state == .ready(book))
        #expect(await effects.events.suffix(5) == ["recovery", "install", "lease", "readiness", "dismiss"])
    }

    @Test("identity changes after each awaited preparation step stop the stale handoff")
    func accountSwitchAtEveryPreparationBoundaryStopsHandoff() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)

        for boundary in ["recovery", "install", "lease", "readiness"] {
            let effects = EffectLog(invalidateIdentityAfter: boundary)
            let coordinator = makeCoordinator(owner: owner, book: book, effects: effects, openResult: true)

            await coordinator.selectSample()

            #expect(coordinator.state == .failed)
            let events = await effects.events
            #expect(events.contains(boundary))
            #expect(events.contains("dismiss") == false)
            #expect(events.contains("tour") == false)
            #expect(events.contains("open") == false)
            #expect(events.contains("seen") == false)
            #expect(events.contains("clearRecovery") == false)
            if boundary == "lease" || boundary == "readiness" {
                await effects.waitForLeaseRelease()
                let events = await effects.events
                #expect(events.contains("leaseReleased"))
            }
        }
    }

    @Test("installation and lease acquisition failures keep selection recoverable")
    func installationAndLeaseFailuresAreRecoverable() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)

        let installEffects = EffectLog(failInstall: true)
        let installCoordinator = makeCoordinator(owner: owner, book: book, effects: installEffects, openResult: true)
        await installCoordinator.selectSample()
        #expect(installCoordinator.state == .failed)
        #expect(await installEffects.events.contains("lease") == false)
        #expect(await installEffects.events.contains("clearRecovery") == false)

        let leaseEffects = EffectLog(failLeaseAcquisition: true)
        let leaseCoordinator = makeCoordinator(owner: owner, book: book, effects: leaseEffects, openResult: true)
        await leaseCoordinator.selectSample()
        #expect(leaseCoordinator.state == .failed)
        #expect(await leaseEffects.events.contains("readiness") == false)
        #expect(await leaseEffects.events.contains("clearRecovery") == false)
    }

    @Test("an older acquisition cannot replace or release the newer account's lease")
    func staleAcquisitionCannotOverwriteNewAttemptLease() async throws {
        let firstBook = sampleBook(owner: UUID())
        let secondBook = sampleBook(owner: UUID())
        let firstIdentity = LibraryAccountIdentity(userID: firstBook.userId, generation: 3)
        let secondIdentity = LibraryAccountIdentity(userID: secondBook.userId, generation: 4)
        let harness = SwitchingAttemptHarness(first: firstBook, second: secondBook)
        let releases = LeaseReleaseRecorder()
        let events = AttemptEventLog()
        let coordinator = switchingCoordinator(
            identity: firstIdentity,
            nextBook: { await harness.nextBook() },
            isCurrent: { await harness.isCurrent($0) },
            acquire: { book in
                let attempt = await harness.nextAcquisition()
                if attempt == 1 { await harness.firstAcquireGate.wait() }
                let generation: UInt64 = book.id == firstBook.id ? 3 : 4
                return makeTrackedLease(book: book, generation: generation, label: "lease-\(attempt)", releases: releases)
            },
            events: events
        )

        let firstSelection = Task { await coordinator.selectSample() }
        await harness.firstAcquireGate.waitUntilEntered()
        await harness.switchTo(secondIdentity)
        coordinator.updateIdentity(secondIdentity)
        await coordinator.selectSample()
        #expect(coordinator.state == .ready(secondBook))
        #expect(releases.labels.isEmpty)

        await harness.firstAcquireGate.open()
        await firstSelection.value

        #expect(coordinator.state == .ready(secondBook))
        #expect(releases.labels == ["lease-1"])
        await coordinator.completeDismissal()
        #expect(await events.openedBookIDs == [secondBook.id])
        #expect(coordinator.state == .choosing)
        #expect(releases.labels == ["lease-1", "lease-2"])
    }

    @Test("cancelling the selection caller while install is suspended blocks dismissal and opening")
    func cancelledSelectionCallerCannotDismissOrOpen() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let gate = AsyncGate()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: true,
            installGate: gate
        )

        let caller = Task { await coordinator.selectSample() }
        await gate.waitUntilEntered()
        caller.cancel()
        await gate.open()
        await caller.value

        #expect(coordinator.state == .failed || coordinator.state == .choosing)
        #expect(await effects.events.contains("dismiss") == false)
        #expect(await effects.events.contains("open") == false)
    }

    @Test("host disappearance cancels an installing attempt and returns its state to choosing")
    func hostDisappearanceReturnsInstallingAttemptToChoosing() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let gate = AsyncGate()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: true,
            installGate: gate
        )

        let selection = Task { await coordinator.selectSample() }
        await gate.waitUntilEntered()
        coordinator.hostDidDisappear()
        #expect(coordinator.state == .choosing)
        await gate.open()
        await selection.value

        #expect(coordinator.state == .choosing)
        #expect(await effects.events.contains("dismiss") == false)
        #expect(await effects.events.contains("open") == false)
    }

    @Test("a stale dismissal callback cannot clear the replacement attempt's lease or state")
    func staleDismissalCallbackCannotReleaseReplacementLease() async throws {
        let firstBook = sampleBook(owner: UUID())
        let secondBook = sampleBook(owner: UUID())
        let firstIdentity = LibraryAccountIdentity(userID: firstBook.userId, generation: 3)
        let secondIdentity = LibraryAccountIdentity(userID: secondBook.userId, generation: 4)
        let harness = SwitchingAttemptHarness(first: firstBook, second: secondBook)
        let releases = LeaseReleaseRecorder()
        let events = AttemptEventLog()
        let requestGate = AsyncGate()
        let openGate = AsyncGate()
        let coordinator = switchingCoordinator(
            identity: firstIdentity,
            nextBook: { await harness.nextBook() },
            isCurrent: { await harness.isCurrent($0) },
            acquire: { book in
                let attempt = await harness.nextAcquisition()
                let generation: UInt64 = book.id == firstBook.id ? 3 : 4
                return makeTrackedLease(book: book, generation: generation, label: "lease-\(attempt)", releases: releases)
            },
            events: events,
            requestTour: { bookID in
                if bookID == firstBook.id { await requestGate.wait() }
            },
            open: { book in
                await openGate.wait()
                return true
            }
        )

        await coordinator.selectSample()
        let oldDismissal = Task { await coordinator.completeDismissal() }
        await requestGate.waitUntilEntered()
        await harness.switchTo(secondIdentity)
        coordinator.updateIdentity(secondIdentity)
        await coordinator.selectSample()
        #expect(coordinator.state == .ready(secondBook))
        let newDismissal = Task { await coordinator.completeDismissal() }
        await openGate.waitUntilEntered()

        await requestGate.open()
        await oldDismissal.value

        #expect(coordinator.state == .ready(secondBook))
        #expect(releases.labels == ["lease-1"])
        #expect(await events.requestedTourBookIDs == [firstBook.id, secondBook.id])
        // Once attempt B owns the coordinator, A must not clear its pending tour state.
        #expect(await events.clearedTourBookIDs.isEmpty)
        await openGate.open()
        await newDismissal.value
        #expect(await events.openedBookIDs == [secondBook.id])
        #expect(coordinator.state == .choosing)
        #expect(releases.labels == ["lease-1", "lease-2"])
    }

    @Test("a delayed stale identity check during dismissal cannot open or mutate a replacement attempt")
    func delayedDismissalIdentityCheckIsAttemptScoped() async throws {
        let firstBook = sampleBook(owner: UUID())
        let secondBook = sampleBook(owner: UUID())
        let firstIdentity = LibraryAccountIdentity(userID: firstBook.userId, generation: 3)
        let secondIdentity = LibraryAccountIdentity(userID: secondBook.userId, generation: 4)
        let harness = SwitchingAttemptHarness(first: firstBook, second: secondBook)
        let releases = LeaseReleaseRecorder()
        let events = AttemptEventLog()
        let identityGate = AsyncGate()
        let checkCount = IdentityCheckCounter()
        let coordinator = switchingCoordinator(
            identity: firstIdentity,
            nextBook: { await harness.nextBook() },
            isCurrent: { identity in
                let count = await checkCount.next()
                if identity == firstIdentity && count == 6 { await identityGate.wait() }
                return await harness.isCurrent(identity)
            },
            acquire: { book in
                let attempt = await harness.nextAcquisition()
                let generation: UInt64 = book.id == firstBook.id ? 3 : 4
                return makeTrackedLease(book: book, generation: generation, label: "lease-\(attempt)", releases: releases)
            },
            events: events
        )

        await coordinator.selectSample()
        let oldDismissal = Task { await coordinator.completeDismissal() }
        await identityGate.waitUntilEntered()
        await harness.switchTo(secondIdentity)
        coordinator.updateIdentity(secondIdentity)
        await coordinator.selectSample()
        #expect(coordinator.state == .ready(secondBook))

        await identityGate.open()
        await oldDismissal.value

        #expect(coordinator.state == .ready(secondBook))
        #expect(releases.labels == ["lease-1"])
        #expect(await events.openedBookIDs.isEmpty)
        #expect(await events.markedSeenUserIDs.isEmpty)
        await coordinator.completeDismissal()
        #expect(await events.openedBookIDs == [secondBook.id])
        #expect(await events.markedSeenUserIDs == [secondBook.userId])
        #expect(coordinator.state == .choosing)
        #expect(releases.labels == ["lease-1", "lease-2"])
    }

    @Test("retired sample source lease after tour request triggers tour cleanup and preserves recovery")
    func sampleSourceRevocationDuringOpenClearsTourAndPreservesRecovery() async throws {
        let book = sampleBook(owner: UUID())
        let identity = LibraryAccountIdentity(userID: book.userId, generation: 3)
        let harness = SwitchingAttemptHarness(first: book, second: book)
        let events = AttemptEventLog()
        let releases = LeaseReleaseRecorder()
        let leaseSlot = BookSourceLeaseSlot()
        let openGate = AsyncGate()
        let coordinator = switchingCoordinator(
            identity: identity,
            nextBook: { await harness.nextBook() },
            isCurrent: { await harness.isCurrent($0) },
            acquire: { sample in
                let lease = makeTrackedLease(book: sample, label: "sample", releases: releases)
                leaseSlot.store(lease)
                return lease
            },
            events: events,
            open: { _ in
                await openGate.wait()
                return true
            }
        )

        await coordinator.selectSample()
        let dismissal = Task { await coordinator.completeDismissal() }
        await openGate.waitUntilEntered()
        let lease = try #require(leaseSlot.value)
        lease.effectAuthority.closeAdmission(lease.sourceAccessPermit)
        await openGate.open()
        await dismissal.value

        #expect(coordinator.state == .failed)
        #expect(await events.requestedTourBookIDs == [book.id])
        #expect(await events.openedBookIDs == [book.id])
        #expect(await events.clearedTourBookIDs == [book.id])
        #expect(await events.markedSeenUserIDs.isEmpty)
        #expect(await events.recoveryWrites == [identity.userID])
        #expect(await events.recoveryClears.isEmpty)
    }

    @Test("cancelling dismissal during open clears the tour and leaves the sample recoverable")
    func cancelledDismissalDuringOpenCleansUpAndCanRetry() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let openGate = AsyncGate()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: true,
            openGate: openGate
        )

        await coordinator.selectSample()
        let dismissal = Task { await coordinator.completeDismissal() }
        await openGate.waitUntilEntered()
        dismissal.cancel()
        await openGate.open()
        await dismissal.value
        await effects.waitForLeaseRelease()

        #expect(coordinator.state == .failed)
        #expect(await effects.events.suffix(4) == ["tour", "open", "clearTour", "leaseReleased"])
        #expect(await effects.events.contains("seen") == false)
        #expect(await effects.events.contains("clearRecovery") == false)
        #expect(await effects.events.filter { $0 == "recovery" }.count == 1)
        #expect(await effects.leaseReleaseCount == 1)

        await coordinator.retry()
        #expect(coordinator.state == .ready(book))
    }

    @Test("retired personal-import source lease blocks opening after identity validation resumes")
    func personalSourceRevocationDuringIdentityCheckBlocksOpen() async throws {
        let owner = UUID()
        let identity = LibraryAccountIdentity(userID: owner, generation: 3)
        let book = sampleBook(owner: owner)
        let harness = PersonalHandoffHarness(identity: identity, suspendAtCheck: 1)
        let events = PersonalHandoffEvents()
        let coordinator = makePersonalCoordinator(
            identity: identity,
            isCurrent: { await harness.isCurrent($0) },
            events: events,
            open: { sample in await events.open(sample); return true }
        )
        let lease = makeTrackedLease(book: book, label: "personal", releases: LeaseReleaseRecorder())

        let handoff = Task { await coordinator.acceptOwnedPersonalImportHandoff(book, lease: lease) }
        await harness.gate.waitUntilEntered()
        lease.effectAuthority.closeAdmission(lease.sourceAccessPermit)
        await harness.gate.open()

        #expect(await handoff.value == false)
        #expect(await events.openedBookIDs.isEmpty)
        #expect(await events.seenUserIDs.isEmpty)
        #expect(await events.recoveryClears.isEmpty)
    }

    @Test("rapid taps share one installation and a failed open leaves the prompt recoverable")
    func repeatedTapCoalescingAndOpenFailure() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let gate = AsyncGate()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: false,
            installGate: gate
        )

        let firstSelection = Task { await coordinator.selectSample() }
        await gate.waitUntilEntered()
        let secondSelection = Task { await coordinator.selectSample() }
        await gate.open()
        await firstSelection.value
        await secondSelection.value

        #expect(await effects.events.filter { $0 == "install" }.count == 1)
        #expect(coordinator.state == .ready(book))
        await coordinator.completeDismissal()
        await effects.waitForLeaseRelease()
        #expect(coordinator.state == .failed)
        #expect(await effects.events.suffix(4) == ["tour", "open", "clearTour", "leaseReleased"])
        #expect(await effects.events.contains("seen") == false)
        #expect(await effects.events.contains("clearRecovery") == false)
    }

    @Test("Catalyst accepts a false open result only when the exact owned reader window exists")
    func existingCatalystWindowAcceptsFocusedHandoff() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        await effects.setExactWindowExists(true)
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: false,
            platform: .catalyst
        )

        await coordinator.selectSample()
        await coordinator.completeDismissal()
        await effects.waitForLeaseRelease()

        #expect(coordinator.state == .choosing)
        let handoffEvents = await effects.events.filter { $0 != "leaseReleased" }
        #expect(handoffEvents.suffix(5) == ["tour", "open", "clearTour", "seen", "clearRecovery"])
    }

    @Test("Catalyst false open without the exact owned window remains recoverable")
    func missingCatalystWindowRejectsHandoff() async throws {
        let owner = UUID()
        let book = sampleBook(owner: owner)
        let effects = EffectLog()
        let coordinator = makeCoordinator(
            owner: owner,
            book: book,
            effects: effects,
            openResult: false,
            platform: .catalyst
        )

        await coordinator.selectSample()
        await coordinator.completeDismissal()
        await effects.waitForLeaseRelease()

        #expect(coordinator.state == .failed)
        #expect(await effects.events.suffix(4) == ["tour", "open", "clearTour", "leaseReleased"])
        #expect(await effects.events.contains("seen") == false)
        #expect(await effects.events.contains("clearRecovery") == false)
    }

    @Test("intentional Skip marks the prompt seen and clears recovery without opening a book")
    func skipIsIntentionalDismissal() async throws {
        let owner = UUID()
        let effects = EffectLog()
        let coordinator = makeCoordinator(owner: owner, book: sampleBook(owner: owner), effects: effects, openResult: true)

        await coordinator.skip()

        #expect(await effects.events == ["seen", "clearRecovery"])
        #expect(coordinator.state == .choosing)
    }

    @Test("repeated intentional dismissals record seen and clear recovery only once")
    func repeatedIntentionalDismissalsAreIdempotent() async throws {
        let owner = UUID()
        let effects = EffectLog()
        let coordinator = makeCoordinator(
            owner: owner,
            book: sampleBook(owner: owner),
            effects: effects,
            openResult: true
        )

        await coordinator.completeIntentionalDismissal()
        await coordinator.completeIntentionalDismissal()

        #expect(await effects.events.filter { $0 == "seen" }.count == 1)
        #expect(await effects.events.filter { $0 == "clearRecovery" }.count == 1)
    }

    @Test("unsafe sample provenance is a non-retryable coordinator failure")
    func provenanceRefusalDoesNotRetryInstall() async throws {
        let owner = UUID()
        let effects = EffectLog(failInstallWithProvenance: true)
        let coordinator = makeCoordinator(
            owner: owner,
            book: sampleBook(owner: owner),
            effects: effects,
            openResult: true
        )

        await coordinator.selectSample()
        #expect(coordinator.state == .failed)
        #expect(coordinator.failureKind == .provenanceUnavailable)
        await coordinator.retry()

        #expect(await effects.events.filter { $0 == "install" }.count == 1)
        #expect(await effects.events.contains("lease") == false)
        #expect(await effects.events.contains("clearRecovery") == false)
    }

    @Test("cancelling a personal handoff during its initial identity check prevents opening")
    func cancelledPersonalHandoffDoesNotOpen() async throws {
        let owner = UUID()
        let identity = LibraryAccountIdentity(userID: owner, generation: 3)
        let book = sampleBook(owner: owner)
        let harness = PersonalHandoffHarness(identity: identity, suspendAtCheck: 1)
        let events = PersonalHandoffEvents()
        let coordinator = makePersonalCoordinator(
            identity: identity,
            isCurrent: { await harness.isCurrent($0) },
            events: events,
            open: { book in await events.open(book); return true }
        )
        let releases = LeaseReleaseRecorder()
        let lease = makeTrackedLease(book: book, generation: 3, label: "personal", releases: releases)

        let handoff = Task { await coordinator.acceptOwnedPersonalImportHandoff(book, lease: lease) }
        await harness.gate.waitUntilEntered()
        handoff.cancel()
        await harness.gate.open()

        #expect(await handoff.value == false)
        #expect(await events.openedBookIDs.isEmpty)
        #expect(await events.seenUserIDs.isEmpty)
    }

    @Test("identity change during final personal-handoff validation prevents stale seen and recovery writes")
    func stalePersonalHandoffCannotMarkSeenOrClearRecovery() async throws {
        let owner = UUID()
        let identity = LibraryAccountIdentity(userID: owner, generation: 3)
        let nextIdentity = LibraryAccountIdentity(userID: UUID(), generation: 4)
        let book = sampleBook(owner: owner)
        let harness = PersonalHandoffHarness(identity: identity, suspendAtCheck: 2)
        let events = PersonalHandoffEvents()
        let coordinator = makePersonalCoordinator(
            identity: identity,
            isCurrent: { await harness.isCurrent($0) },
            events: events,
            open: { book in await events.open(book); return true }
        )
        let lease = makeTrackedLease(book: book, generation: 3, label: "personal", releases: LeaseReleaseRecorder())

        let handoff = Task { await coordinator.acceptOwnedPersonalImportHandoff(book, lease: lease) }
        await harness.gate.waitUntilEntered()
        await harness.switchTo(nextIdentity)
        coordinator.updateIdentity(nextIdentity)
        await harness.gate.open()

        #expect(await handoff.value == false)
        #expect(await events.openedBookIDs == [book.id])
        #expect(await events.seenUserIDs.isEmpty)
        #expect(await events.recoveryClears.isEmpty)
    }

    @Test("sample selection stays serialized while personal-import handoff is suspended")
    func sampleSelectionCannotStartDuringPersonalHandoff() async throws {
        let owner = UUID()
        let identity = LibraryAccountIdentity(userID: owner, generation: 3)
        let book = sampleBook(owner: owner)
        let harness = PersonalHandoffHarness(identity: identity)
        let events = PersonalHandoffEvents()
        let openGate = AsyncGate()
        let coordinator = makePersonalCoordinator(
            identity: identity,
            isCurrent: { await harness.isCurrent($0) },
            events: events,
            open: { book in
                await events.open(book)
                await openGate.wait()
                return true
            }
        )
        let lease = makeTrackedLease(book: book, generation: 3, label: "personal", releases: LeaseReleaseRecorder())

        let handoff = Task { await coordinator.acceptOwnedPersonalImportHandoff(book, lease: lease) }
        await openGate.waitUntilEntered()
        await coordinator.selectSample()
        #expect(await events.installCount == 0)
        #expect(coordinator.state == .choosing)

        await openGate.open()
        #expect(await handoff.value)
        #expect(await events.installCount == 0)
    }

    private func makeCoordinator(
        owner: UserID,
        book: Book,
        effects: EffectLog,
        openResult: Bool,
        platform: FirstBookSampleCoordinator.Platform = .ios,
        installGate: AsyncGate? = nil,
        openGate: AsyncGate? = nil
    ) -> FirstBookSampleCoordinator {
        FirstBookSampleCoordinator(
            identity: LibraryAccountIdentity(userID: owner, generation: 3),
            platform: platform,
            install: {
                await effects.record("install")
                if await effects.shouldFailInstallWithProvenance() {
                    throw SampleBookInstallerError.provenanceUnavailable
                }
                if await effects.shouldFailInstallation() { throw TestFailure.installation }
                if let installGate { await installGate.wait() }
                return book
            },
            acquireLease: { sample in
                await effects.record("lease")
                if await effects.shouldFailLeaseAcquisition() { throw TestFailure.acquisition }
                return makeTrackedLease(
                    book: sample,
                    generation: 3,
                    label: "sample",
                    releases: { Task { await effects.record("leaseReleased") } }
                )
            },
            ensureReady: { _ in
                await effects.record("readiness")
                if await effects.consumeReadinessFailure() { throw TestFailure.readiness }
            },
            isCurrentIdentity: { _ in await effects.identityIsCurrent() },
            persistRecovery: { _ in await effects.record("recovery") },
            dismiss: { await effects.record("dismiss") },
            markSeen: { _ in await effects.record("seen") },
            requestTour: { _, _ in await effects.record("tour") },
            openBook: { _ in
                await effects.record("open")
                if let openGate { await openGate.wait() }
                return openResult
            },
            hasOwnedReaderWindow: { id in await effects.hasExactWindow(owner: id.userID, book: id.bookID) },
            clearTourRequest: { _, _ in await effects.record("clearTour") },
            clearRecovery: { _ in await effects.record("clearRecovery") }
        )
    }

    private func sampleBook(owner: UserID) -> Book {
        Book(userId: owner, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
    }

    private func switchingCoordinator(
        identity: LibraryAccountIdentity,
        nextBook: @escaping @Sendable () async -> Book,
        isCurrent: @escaping @Sendable (LibraryAccountIdentity) async -> Bool,
        acquire: @escaping @Sendable (Book) async throws -> BookSourceLease,
        events: AttemptEventLog,
        requestTour: (@Sendable (BookID) async -> Void)? = nil,
        open: (@Sendable (Book) async -> Bool)? = nil
    ) -> FirstBookSampleCoordinator {
        FirstBookSampleCoordinator(
            identity: identity,
            install: { await nextBook() },
            acquireLease: acquire,
            ensureReady: { _ in },
            isCurrentIdentity: { await isCurrent($0) },
            persistRecovery: { identity in await events.recordRecovery(identity.userID) },
            dismiss: {},
            markSeen: { identity in await events.recordSeen(identity.userID) },
            requestTour: { _, bookID in
                await events.recordTour(bookID)
                await requestTour?(bookID)
            },
            openBook: { book in
                await events.recordOpen(book.id)
                return await open?(book) ?? true
            },
            hasOwnedReaderWindow: { _ in false },
            clearTourRequest: { _, bookID in await events.recordTourClear(bookID) },
            clearRecovery: { identity in await events.clearRecovery(identity.userID) }
        )
    }

    private func makePersonalCoordinator(
        identity: LibraryAccountIdentity,
        isCurrent: @escaping @Sendable (LibraryAccountIdentity) async -> Bool,
        events: PersonalHandoffEvents,
        open: @escaping @Sendable (Book) async -> Bool
    ) -> FirstBookSampleCoordinator {
        let book = sampleBook(owner: identity.userID)
        return FirstBookSampleCoordinator(
            identity: identity,
            install: { await events.recordInstall(); return book },
            acquireLease: { sample in
                makeTrackedLease(
                    book: sample,
                    generation: identity.generation,
                    label: "sample",
                    releases: LeaseReleaseRecorder()
                )
            },
            ensureReady: { _ in },
            isCurrentIdentity: { await isCurrent($0) },
            persistRecovery: { _ in },
            dismiss: {},
            markSeen: { value in await events.markSeen(value.userID) },
            requestTour: { _, _ in },
            openBook: open,
            hasOwnedReaderWindow: { _ in false },
            clearTourRequest: { _, _ in },
            clearRecovery: { value in await events.clearRecovery(value.userID) }
        )
    }
}

private enum TestFailure: Error { case readiness, acquisition, installation }

private actor EffectLog {
    private(set) var events: [String] = []
    private var readinessFailures = 0
    private var exactWindowExists = false
    private var identityCurrent = true
    private let invalidateIdentityAfter: String?
    private let failLeaseAcquisition: Bool
    private let failInstall: Bool
    private let failInstallWithProvenance: Bool
    private(set) var leaseReleaseCount = 0
    private var leaseReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        invalidateIdentityAfter: String? = nil,
        failLeaseAcquisition: Bool = false,
        failInstall: Bool = false,
        failInstallWithProvenance: Bool = false
    ) {
        self.invalidateIdentityAfter = invalidateIdentityAfter
        self.failLeaseAcquisition = failLeaseAcquisition
        self.failInstall = failInstall
        self.failInstallWithProvenance = failInstallWithProvenance
    }

    func record(_ event: String) {
        events.append(event)
        if event == "leaseReleased" {
            leaseReleaseCount += 1
            let waiters = leaseReleaseWaiters
            leaseReleaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if event == invalidateIdentityAfter { identityCurrent = false }
    }
    func waitForLeaseRelease() async {
        guard leaseReleaseCount == 0 else { return }
        await withCheckedContinuation { leaseReleaseWaiters.append($0) }
    }
    func failNextReadiness() { readinessFailures += 1 }
    func consumeReadinessFailure() -> Bool {
        guard readinessFailures > 0 else { return false }
        readinessFailures -= 1
        return true
    }
    func setExactWindowExists(_ value: Bool) { exactWindowExists = value }
    func hasExactWindow(owner: UserID, book: BookID) -> Bool { exactWindowExists }
    func identityIsCurrent() -> Bool { identityCurrent }
    func shouldFailLeaseAcquisition() -> Bool { failLeaseAcquisition }
    func shouldFailInstallation() -> Bool { failInstall }
    func shouldFailInstallWithProvenance() -> Bool { failInstallWithProvenance }
}

private actor AsyncGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor SwitchingAttemptHarness {
    let firstAcquireGate = AsyncGate()
    private let books: [Book]
    private var installCount = 0
    private var acquisitionCount = 0
    private var currentIdentity: LibraryAccountIdentity

    init(first: Book, second: Book) {
        books = [first, second]
        currentIdentity = LibraryAccountIdentity(userID: first.userId, generation: 3)
    }
    func nextBook() -> Book {
        let book = books[min(installCount, books.count - 1)]
        installCount += 1
        return book
    }
    func nextAcquisition() -> Int {
        acquisitionCount += 1
        return acquisitionCount
    }
    func isCurrent(_ identity: LibraryAccountIdentity) -> Bool { currentIdentity == identity }
    func switchTo(_ identity: LibraryAccountIdentity) { currentIdentity = identity }
}

private final class LeaseReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLabels: [String] = []
    var labels: [String] { lock.lock(); defer { lock.unlock() }; return storedLabels }
    func record(_ label: String) { lock.lock(); storedLabels.append(label); lock.unlock() }
}

private func makeTrackedLease(
    book: Book,
    generation: UInt64 = 3,
    label: String,
    releases: LeaseReleaseRecorder
) -> BookSourceLease {
    makeTrackedLease(book: book, generation: generation, label: label) {
        releases.record(label)
    }
}

private func makeTrackedLease(
    book: Book,
    generation: UInt64 = 3,
    label: String,
    releases: @escaping @Sendable () -> Void
) -> BookSourceLease {
    let permit = BookSourceAccessPermit()
    let authority = BookSourceEffectAuthority()
    authority.register(permit)
    let readingPermit = BookReadingPermit(
        ownerID: book.userId,
        accountGeneration: generation,
        bookID: book.id,
        contentRevision: UUID()
    )
    let sourceOwner = try! BookSourceOwner(
        url: URL(fileURLWithPath: "/tmp/\(label).epub"),
        access: .account(readingPermit),
        sourceAccessPermit: permit,
        effectAuthority: authority
    )
    return BookSourceLease(owner: sourceOwner, cachePolicy: .transient, release: releases)
}

private actor AttemptEventLog {
    private(set) var openedBookIDs: [BookID] = []
    private(set) var markedSeenUserIDs: [UserID] = []
    private(set) var requestedTourBookIDs: [BookID] = []
    private(set) var clearedTourBookIDs: [BookID] = []
    private(set) var recoveryWrites: [UserID] = []
    private(set) var recoveryClears: [UserID] = []
    func recordOpen(_ bookID: BookID) { openedBookIDs.append(bookID) }
    func recordSeen(_ userID: UserID) { markedSeenUserIDs.append(userID) }
    func recordRecovery(_ userID: UserID) { recoveryWrites.append(userID) }
    func clearRecovery(_ userID: UserID) { recoveryClears.append(userID) }
    func recordTour(_ bookID: BookID) { requestedTourBookIDs.append(bookID) }
    func recordTourClear(_ bookID: BookID) { clearedTourBookIDs.append(bookID) }
}

private final class BookSourceLeaseSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: BookSourceLease?
    var value: BookSourceLease? { lock.lock(); defer { lock.unlock() }; return storedValue }
    func store(_ lease: BookSourceLease) { lock.lock(); storedValue = lease; lock.unlock() }
}

private actor IdentityCheckCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor PersonalHandoffHarness {
    let gate = AsyncGate()
    private var identity: LibraryAccountIdentity
    private let suspendAtCheck: Int?
    private var checkCount = 0
    init(identity: LibraryAccountIdentity, suspendAtCheck: Int? = nil) {
        self.identity = identity
        self.suspendAtCheck = suspendAtCheck
    }
    func isCurrent(_ expected: LibraryAccountIdentity) async -> Bool {
        checkCount += 1
        if checkCount == suspendAtCheck { await gate.wait() }
        return identity == expected
    }
    func switchTo(_ value: LibraryAccountIdentity) { identity = value }
}

private actor PersonalHandoffEvents {
    private(set) var openedBookIDs: [BookID] = []
    private(set) var seenUserIDs: [UserID] = []
    private(set) var recoveryClears: [UserID] = []
    private(set) var installCount = 0
    func open(_ book: Book) { openedBookIDs.append(book.id) }
    func markSeen(_ userID: UserID) { seenUserIDs.append(userID) }
    func clearRecovery(_ userID: UserID) { recoveryClears.append(userID) }
    func recordInstall() { installCount += 1 }
}

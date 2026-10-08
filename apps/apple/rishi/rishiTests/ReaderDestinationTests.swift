import Foundation
import Testing
@testable import rishi

@Suite("Reader destination read-aloud prompts")
struct ReaderDestinationTests {
    @Test("paused promotion publishes visible reader position over an old narration anchor")
    func pausedPromotionSelectsVisiblePosition() {
        let visible = SharedReadingPosition(href: "chapter-4.xhtml", page: 4, progression: 0.31)
        let oldNarration = SharedReadingPosition(href: "chapter-2.xhtml", page: 2, progression: 0.72)

        let selected = SharedReadingControllerPromotionPositionSelector.select(
            isActivelySpeaking: false,
            visiblePosition: visible,
            narrationPosition: oldNarration,
            effectiveRate: 1.5
        )

        #expect(selected?.position == SharedReadingDesiredPosition(position: visible, source: .reader))
        #expect(selected?.rate == 1.5)
        #expect(oldNarration != selected?.position.position)
    }

    @Test("speaking promotion publishes current narration position without replacing visible observation")
    func speakingPromotionSelectsNarrationPosition() {
        let visible = SharedReadingPosition(href: "chapter-4.xhtml", page: 4, progression: 0.31)
        let narration = SharedReadingPosition(href: "chapter-5.xhtml", page: 5, progression: 0.12)

        let selected = SharedReadingControllerPromotionPositionSelector.select(
            isActivelySpeaking: true,
            visiblePosition: visible,
            narrationPosition: narration,
            effectiveRate: 1.5
        )

        #expect(selected?.position == SharedReadingDesiredPosition(position: narration, source: .readAloud))
        #expect(selected?.rate == 1.5)
        #expect(visible != selected?.position.position)
    }

    @Test("combined rate and narration-cursor correction plans one restart at the latest cursor")
    func combinedFollowerAudioChangesUseLatestCursorForSingleRestart() {
        let supersededCursor = SharedReadingPosition(href: "chapter-3.xhtml", page: 3, progression: 0.4)
        let latestCursor = SharedReadingPosition(href: "chapter-6.xhtml", page: 6, progression: 0.18)

        let plan = SharedFollowerAudioReconfigurationPlan.make(
            rate: 1.5,
            cursor: latestCursor,
            phase: .playing,
            rateChanged: true,
            cursorNeedsRealignment: true
        )

        #expect(plan.rate == 1.5)
        #expect(plan.cursor == latestCursor)
        #expect(plan.restartAt == latestCursor)
        #expect(plan.restartAt != supersededCursor)
    }

    @Test("voice handoff cannot start narration independently while following a shared controller")
    func voiceHandoffStartIsFollowerGatedAndAvailableOutsideSharedReading() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let handoffStart = try #require(source.range(of: "onOpenReadAloud: {"))
        let handoffEnd = try #require(source.range(of: "onEndVoice:", range: handoffStart.lowerBound..<source.endIndex))
        let handoff = source[handoffStart.lowerBound..<handoffEnd.lowerBound]
        let followerGate = try #require(
            handoff.range(of: "guard !sharedIsFollowingController && !sharedControlsLocked else { return }")
        )
        let localStart = try #require(handoff.range(of: "playbackOwner.start("))
        let localResume = try #require(handoff.range(of: "openReadAloudFromVoice(vm: vm)"))
        let requestEnd = try #require(handoff.range(of: "await dependencies.voicePresenter.requestEnd()"))

        #expect(requestEnd.lowerBound < followerGate.lowerBound)
        #expect(followerGate.lowerBound < localStart.lowerBound)
        #expect(followerGate.lowerBound < localResume.lowerBound)
    }

    @Test("voice transport prewarm stays gated until the reader tour requests it")
    func voicePrewarmIsNotStartedForEveryReaderEntry() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("if startReaderTour"))
        #expect(source.contains("prewarmVoiceChat(for: vm.book.id, userID: userId)"))
    }

    @Test("reader backfills the voice index even if PDF skips its first location callback")
    func readerIndexBackfillHasPDFFallback() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("PDF-only"))
        #expect(source.contains("if vm.book.formatType == .pdf"))
        #expect(source.contains("await scheduleReaderIndexBackfillIfNeeded()"))
        #expect(source.contains("didScheduleReaderIndexBackfill = true"))
    }

    @Test("source invalidation awaits reader voice cleanup before removing the leased reader")
    func sourceInvalidationDrainsReaderVoiceBeforeLeaseRemoval() throws {
        let hostURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestinationView.swift")
        let host = try String(contentsOf: hostURL, encoding: .utf8)
        let invalidationStart = try #require(host.range(of: "for await _ in lease.invalidation"))
        let invalidationEnd = try #require(host.range(of: "break", range: invalidationStart.lowerBound..<host.endIndex))
        let invalidation = host[invalidationStart.lowerBound..<invalidationEnd.lowerBound]
        let cleanup = try #require(invalidation.range(of: "await cleanup.perform()"))
        let removal = try #require(invalidation.range(of: "self.lease = nil"))

        #expect(cleanup.lowerBound < removal.lowerBound)

        let readerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let reader = try String(contentsOf: readerURL, encoding: .utf8)
        #expect(reader.contains("await attachment.registerCleanup()"))
        let attachmentURL = readerURL.deletingLastPathComponent().appendingPathComponent("ReaderSourceAttachment.swift")
        let attachment = try String(contentsOf: attachmentURL, encoding: .utf8)
        #expect(attachment.contains("cleanup.register(action)"))
        #expect(attachment.contains("await voiceEntry.endForReader()"))
        #expect(reader.contains("await voiceEntry.endForReader()"))
    }

    @Test("source invalidation runs cleanup for every reader identity sharing the lease")
    @MainActor
    func sourceInvalidationCleanupComposesReaderEntries() async {
        let cleanup = ReaderSourceInvalidationCleanup()
        var endedEntries: [Int] = []
        cleanup.register { endedEntries.append(1) }
        cleanup.register { endedEntries.append(2) }

        await cleanup.perform()

        #expect(endedEntries == [1, 2])
    }

    @Test("reader exit ends voice instead of parking it")
    func readerExitEndsVoiceSession() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("await voiceEntry.endForReader()"))
        #expect(!source.contains("await voicePresenter.parkSession()"))
    }

    @Test("message dirty mark completes under the source admission held across a committed upsert")
    func committedMessageDirtyMarkIsSourceAdmitted() async throws {
        let source = BookSourceAccessPermit()
        let effects = BookSourceEffectAuthority()
        effects.register(source)
        let commitGate = ReaderCommitGate()
        let message = Message(conversationId: UUID(), role: .user, content: "Hello")
        let base = CommitThenInvalidateMessageStore(source: source, effects: effects)
        let dirtyIDs = ReaderDirtyIDRecorder()
        let store = ReaderSourceAdmittedMessageStore(
            base: base,
            source: source,
            effects: effects,
            onCommitted: { id in
                await dirtyIDs.record(id)
                await commitGate.wait()
            }
        )

        let write = Task { try await store.upsert(message) }
        await commitGate.waitUntilEntered()
        let drained = ReaderDrainRecorder()
        let drain = Task {
            await effects.drain(source)
            await drained.mark()
        }
        await Task.yield()
        #expect(await !drained.value)
        await commitGate.open()
        try await write.value
        await drain.value

        #expect(try await base.message(message.id) == message)
        #expect(await dirtyIDs.values == [message.id])
        #expect(await drained.value)
    }

    @Test("reader backfill joins canceled real indexing until the entered extractor unwinds")
    @MainActor
    func readerBackfillCancellationWaitsForRealHook() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let registry = fixture.registry
        let owner = fixture.owner
        let generation = fixture.generation
        let source = try await registry.acquireReadableSource(for: fixture.book)
        let extractor = ReaderBackfillCancellationExtractor()
        let hook = RishiSearchIndexingHook(
            builder: IndexBuilder(rootURL: fixture.root, embedder: IdentityEmbedder()),
            extractors: ["epub": extractor],
            acquireSource: { book in
                BookIndexingSource(identity: .init(ownerID: owner, generation: generation, bookID: book.id),
                                   lease: try await registry.acquireReadableSource(for: book))
            }
        )
        let completed = RishiSearchIndexingHookTests.CompletionRecorder()
        let backfill = Task {
            await ReaderIndexBackfillFence.scheduleAndDrain(
                book: fixture.book, sourceLease: source,
                resolveManagedSource: { try await registry.awaitManagedSource(for: fixture.book) },
                acquireManagedSource: { try await registry.acquireReadableSource(for: fixture.book) },
                indexingHook: hook
            )
            await completed.markCompleted()
        }
        #expect(await RishiSearchIndexingHookTests.waitUntil { await extractor.entered })
        registry.fenceBookSynchronously(ownerID: owner, generation: generation, bookID: fixture.book.id)
        hook.cancelBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        #expect(await !completed.completed)
        await extractor.release()
        #expect(await RishiSearchIndexingHookTests.waitUntil { await completed.completed })
        await backfill.value
        await hook.drainBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        #expect(await extractor.observedCancellation)
        #expect(!FileManager.default.fileExists(atPath: BookIndexLocator(rootURL: fixture.root).vectorsURL(fixture.book.id).path))
    }

    @Test("reader index backfill drains both source revisions until the shared indexing task finishes")
    func readerIndexBackfillWaitsForActualTaskWithStaleStatusAndPromotedRevision() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let selectedRevision = UUID()
        let promotedRevision = UUID()
        let generation: UInt64 = 7
        let book = Book(id: bookID, userId: ownerID, title: "Backfill", formatType: .epub, fileURL: "Books/backfill.epub")
        let selectedReadingPermit = BookReadingPermit(
            ownerID: ownerID,
            accountGeneration: generation,
            bookID: bookID,
            contentRevision: selectedRevision
        )
        let selectedSourcePermit = BookSourceAccessPermit()
        let selectedEffects = BookSourceEffectAuthority()
        selectedEffects.register(selectedSourcePermit)
        let selectedOwner = try BookSourceOwner(
            url: URL(fileURLWithPath: "/tmp/backfill.epub"),
            access: .account(selectedReadingPermit),
            sourceAccessPermit: selectedSourcePermit,
            effectAuthority: selectedEffects
        )
        let selectedLease = BookSourceLease(owner: selectedOwner, cachePolicy: .transient)
        let managedVersion = ManagedFileVersion(
            byteCount: 1,
            modificationDate: .now,
            fileIdentifier: nil,
            materializationRevision: promotedRevision
        )
        let managedPermit = BookSourceAccessPermit()
        let managedEffects = BookSourceEffectAuthority()
        managedEffects.register(managedPermit)
        let managedOwner = try BookSourceOwner(
            url: URL(fileURLWithPath: "/tmp/backfill-managed.epub"),
            access: .account(BookReadingPermit(
                ownerID: ownerID,
                accountGeneration: generation,
                bookID: bookID,
                contentRevision: promotedRevision
            )),
            sourceAccessPermit: managedPermit,
            effectAuthority: managedEffects
        )
        let managedLease = BookSourceLease(
            owner: managedOwner,
            cachePolicy: .managed(bookID: bookID, version: managedVersion)
        )
        let managed = ManagedBookSource(
            bookID: bookID,
            url: managedOwner.url,
            fingerprint: BookFileFingerprint(
                bookID: bookID,
                ownerID: ownerID,
                sha256: "digest",
                version: managedVersion
            ),
            readingPermit: selectedReadingPermit
        )
        let search = ReaderBackfillSearch()
        let scheduled = ReaderIndexScheduleGate()
        let completion = ReaderIndexCompletionGate()
        let indexing = ReaderBackfillIndexingHook(search: search, scheduled: scheduled, completion: completion)

        let backfill = Task {
            await ReaderIndexBackfillFence.scheduleAndDrain(
                book: book,
                sourceLease: selectedLease,
                resolveManagedSource: { managed },
                acquireManagedSource: { managedLease },
                indexingHook: indexing,
            )
        }
        await scheduled.waitUntilScheduled()

        selectedEffects.closeAdmission(selectedSourcePermit)
        managedEffects.closeAdmission(managedPermit)
        let selectedDrained = ReaderDrainRecorder()
        let managedDrained = ReaderDrainRecorder()
        let selectedDrainStarted = ReaderDrainStarted()
        let managedDrainStarted = ReaderDrainStarted()
        let selectedDrain = Task {
            await selectedDrainStarted.mark()
            await selectedEffects.drain(selectedSourcePermit)
            await selectedDrained.mark()
        }
        let managedDrain = Task {
            await managedDrainStarted.mark()
            await managedEffects.drain(managedPermit)
            await managedDrained.mark()
        }
        await selectedDrainStarted.waitUntilStarted()
        await managedDrainStarted.waitUntilStarted()
        await selectedDrain.value
        #expect(await search.status(bookId: bookID) == .staleIndexing)
        #expect(await selectedDrained.value)
        #expect(await !managedDrained.value)

        await completion.open()
        await backfill.value
        await selectedDrain.value
        await managedDrain.value

        #expect(await selectedDrained.value)
        #expect(await managedDrained.value)
    }

    @Test("reader backfill does not hold a transient source while managed readiness is pending")
    func readerIndexBackfillDoesNotBlockSourceDrainDuringManagedWait() async throws {
        let ownerID = UUID()
        let book = Book(userId: ownerID, title: "Waiting", formatType: .epub, fileURL: "Books/waiting.epub")
        let sourcePermit = BookSourceAccessPermit()
        let effects = BookSourceEffectAuthority()
        effects.register(sourcePermit)
        let owner = try BookSourceOwner(
            url: URL(fileURLWithPath: "/tmp/waiting.epub"),
            access: .account(BookReadingPermit(
                ownerID: ownerID,
                accountGeneration: 2,
                bookID: book.id,
                contentRevision: UUID()
            )),
            sourceAccessPermit: sourcePermit,
            effectAuthority: effects
        )
        let lease = BookSourceLease(owner: owner, cachePolicy: .transient)
        let readiness = ReaderManagedReadinessGate()
        let indexing = ReaderBackfillIndexingHook(
            search: ReaderBackfillSearch(),
            scheduled: ReaderIndexScheduleGate(),
            completion: ReaderIndexCompletionGate()
        )
        let backfill = Task {
            await ReaderIndexBackfillFence.scheduleAndDrain(
                book: book,
                sourceLease: lease,
                resolveManagedSource: { try await readiness.waitThenFail() },
                acquireManagedSource: { throw BookSourceRegistryError.unavailable },
                indexingHook: indexing
            )
        }
        await readiness.waitUntilEntered()

        effects.closeAdmission(sourcePermit)
        await effects.drain(sourcePermit)
        await readiness.fail()
        await backfill.value
        #expect(await !indexing.scheduled.didSchedule)
    }

    @Test("reader exit tears down shared playback and preserves platform-specific local host behavior")
    func readerExitStopsReadAloud() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Reader/ReaderDestination.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cleanupStart = try #require(source.range(of: ".onDisappear {\n            didScheduleReaderIndexBackfill = false"))
        let cleanupEnd = try #require(source.range(of: ".overlay(alignment: .bottomTrailing)", range: cleanupStart.lowerBound..<source.endIndex))
        let cleanup = source[cleanupStart.lowerBound..<cleanupEnd.lowerBound]
        let sharedTeardownStart = try #require(cleanup.range(of: "if sharedReadingCoordinator != nil {"))
        let sharedTeardownEnd = try #require(cleanup.range(
            of: "}\n#if !targetEnvironment(macCatalyst)",
            range: sharedTeardownStart.lowerBound..<cleanup.endIndex
        ))
        let sharedTeardown = cleanup[sharedTeardownStart.lowerBound..<sharedTeardownEnd.lowerBound]
        let stop = try #require(sharedTeardown.range(of: "await dependencies.playbackOwner.stop(host: readAloudHost)"))
        let clearRate = try #require(sharedTeardown.range(of: "await readAloud?.clearSharedSessionRate(fence: sharedRateExitFence)"))

        #expect(stop.lowerBound < clearRate.lowerBound)

        let localRelease = try #require(cleanup.range(
            of: "#if !targetEnvironment(macCatalyst)\n                    await dependencies.playbackOwner.release(host: readAloudHost)\n#endif"
        ))
        let localElse = try #require(cleanup.range(of: "else {", range: sharedTeardownEnd.lowerBound..<cleanup.endIndex))
        #expect(localElse.lowerBound < localRelease.lowerBound)
    }

    @Test("library boundaries drain registered voice cleanup on iOS and macOS")
    func libraryBoundariesDrainRegisteredVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Views/SignedInView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("router.path.isEmpty"))
        #expect(source.contains("readerWindows.openWindows.isEmpty"))
        #expect(source.contains("cleanupRegisteredReaderSessions()"))
    }

    @Test("opening another book waits for registered voice cleanup")
    func openingBookWaitsForVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Library/LibraryTabView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let cleanup = try #require(source.range(of: "await dependencies.voicePresenter.cleanupRegisteredReaderSessions()"))
        let route = source.range(of: "router.path.append(ReaderRoute.route(for: book))")
        #expect(route != nil)
        #expect(cleanup.lowerBound < route!.lowerBound)
    }

    @Test("deep-link reader replacement waits for registered voice cleanup")
    func deepLinkReaderReplacementWaitsForVoiceCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/DeepLink/DeepLinkHandlingModifier.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let cleanup = try #require(
            source.range(of: "await services.voice.presenter.cleanupRegisteredReaderSessions()")
        )
        let handle = try #require(source.range(of: "router.handle(") )
        #expect(cleanup.lowerBound < handle.lowerBound)
    }

    @Test("deep-link router awaits cleanup before presenting a resolved book")
    func deepLinkRouterAwaitsCleanupBeforePresentingBook() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/App/AppRouter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("beforePresentingBook"))
        #expect(source.contains("await beforePresentingBook()"))
    }

    @Test("trial allowance failures map to the trial prompt")
    func trialFailureMapsToTrialPrompt() {
        #expect(
            readAloudUpgradeReason(for: .trial(message: "trial exhausted")) == .trialExhausted
        )
    }

    @Test("narration allowance failures map to the narration prompt")
    func narrationFailureMapsToNarrationPrompt() {
        #expect(
            readAloudUpgradeReason(for: .narration(message: "narration exhausted"))
                == .narrationAllowanceExhausted
        )
    }

    @Test("one remaining credit supports narration but not a new Voice Chat session")
    func trialCreditGateUsesFeatureMinimums() {
        let oneCredit = EntitlementSnapshot.trialActive(remainingCredits: 1)
        #expect(oneCredit.blockReason(for: .narration) == nil)
        #expect(oneCredit.blockReason(for: .voiceChat) == .insufficientTrialCreditsForVoiceChat)

        let twoCredits = EntitlementSnapshot.trialActive(remainingCredits: 2)
        #expect(twoCredits.blockReason(for: .voiceChat) == nil)

        let noCredits = EntitlementSnapshot.trialActive(remainingCredits: 0)
        #expect(noCredits.blockReason(for: .narration) == .trialExhausted)
        #expect(noCredits.blockReason(for: .voiceChat) == .trialExhausted)
    }
}

private actor ReaderCommitGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ReaderDrainRecorder {
    private(set) var value = false
    func mark() { value = true }
}

private actor ReaderDrainStarted {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        hasStarted = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ReaderDirtyIDRecorder {
    private(set) var values: [MessageID] = []
    func record(_ id: MessageID) { values.append(id) }
}

private actor ReaderBackfillSearch: BookSearch {
    private var currentStatus: BookSearchStatus = .notIndexed

    func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit] { [] }
    func status(bookId: UUID) async -> BookSearchStatus { currentStatus }
    func setStatus(_ status: BookSearchStatus) { currentStatus = status }
}

private actor ReaderIndexScheduleGate {
    private var isScheduled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markScheduled() {
        isScheduled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilScheduled() async {
        if isScheduled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var didSchedule: Bool { isScheduled }
}

private actor ReaderManagedReadinessGate {
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitThenFail() async throws -> ManagedBookSource {
        hasEntered = true
        let pending = entryWaiters
        entryWaiters.removeAll()
        pending.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        throw BookSourceRegistryError.unavailable
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func fail() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ReaderIndexCompletionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct ReaderBackfillIndexingHook: AwaitableBookIndexingHook {
    let search: ReaderBackfillSearch
    let scheduled: ReaderIndexScheduleGate
    let completion: ReaderIndexCompletionGate

    func scheduleIndexing(for book: Book, fileURL: URL) async {
        await search.setStatus(.staleIndexing)
        await scheduled.markScheduled()
    }

    func scheduleIndexingAndWait(for book: Book, fileURL: URL) async {
        await scheduleIndexing(for: book, fileURL: fileURL)
        await completion.wait()
    }
}

private actor CommitThenInvalidateMessageStore: MessageStore {
    private let source: BookSourceAccessPermit
    private let effects: BookSourceEffectAuthority
    private var stored: [MessageID: Message] = [:]

    init(source: BookSourceAccessPermit, effects: BookSourceEffectAuthority) {
        self.source = source
        self.effects = effects
    }

    func messages(for conversationId: ConversationID) async throws -> [Message] {
        stored.values.filter { $0.conversationId == conversationId }
    }
    func message(_ id: MessageID) async throws -> Message? { stored[id] }
    func upsert(_ message: Message) async throws {
        stored[message.id] = message
        effects.closeAdmission(source)
    }
    func delete(_ id: MessageID) async throws { stored.removeValue(forKey: id) }
}

private actor ReaderBackfillCancellationExtractor: PerBookTextExtractor {
    private let gate = RishiSearchIndexingHookTests.RishiReaderLoadGate()
    private(set) var entered = false
    private(set) var observedCancellation = false

    func extractParagraphs(from _: URL) async throws -> [(page: Int, text: String)] {
        entered = true
        await gate.wait()
        observedCancellation = Task.isCancelled
        return [(1, "entered read")]
    }

    func release() async { await gate.open() }
}

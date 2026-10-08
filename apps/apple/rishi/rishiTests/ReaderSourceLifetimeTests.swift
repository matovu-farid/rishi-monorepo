import Foundation
import ReadiumShared
import Testing
@testable import rishi

@Suite("Reader source ownership and attachment teardown")
@MainActor
struct ReaderSourceLifetimeTests {
    /// Observes real registry admissions without invoking its destructive
    /// close/drain operations while the reader still needs authority.
    private final class TrackingSourceEffects: BookSourceEffectAdmitting, @unchecked Sendable {
        private let base: any BookSourceEffectAdmitting
        private let lock = NSLock()
        private var count = 0
        var activeCount: Int { lock.withLock { count } }
        init(base: any BookSourceEffectAdmitting) { self.base = base }
        func admit(_ permit: BookSourceAccessPermit) throws -> SourceEffectAdmission {
            let admitted = try base.admit(permit)
            lock.withLock { count += 1 }
            return SourceEffectAdmission { [self] in
                admitted.release()
                lock.withLock { count -= 1 }
            }
        }
        func closeAdmission(_ permit: BookSourceAccessPermit) { base.closeAdmission(permit) }
        func drain(_ permit: BookSourceAccessPermit) async { await base.drain(permit) }
    }

    @Test("dropping a binding clears only its callback and releases the managed lease")
    func bindingDropsWithoutStop() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        var lease: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var reader: ReaderViewModel? = fixture.makeReader(lease: try #require(lease))
        var commits = 0
        var binding: ReaderPositionSyncBinding? = ReaderPositionSyncBinding(
            viewModel: try #require(reader), sourceLease: try #require(lease)
        ) { _, persist in
            try await persist()
            commits += 1
            return .committed
        }
        weak var weakBinding = binding
        weak var weakReader = reader
        weak var weakLease = lease
        reader?.didChangeLocation(try ReaderDeletionFixture.locator())
        await reader?.flush()
        #expect(commits == 1)
        binding = nil
        reader = nil
        lease = nil
        #expect(await readerLifetimeEventually { weakBinding == nil && weakReader == nil && weakLease == nil })
    }

    @Test("stop is idempotent while a finite admitted commit completes")
    func admittedMarkSurvivesStop() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let gate = ReaderLifetimeGate()
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let reader = fixture.makeReader(lease: lease)
        var commits = 0
        let binding = ReaderPositionSyncBinding(viewModel: reader, sourceLease: lease) { _, persist in
            try await persist()
            commits += 1
            await gate.wait(cancellationAware: false)
            return .committed
        }
        reader.didChangeLocation(try ReaderDeletionFixture.locator())
        let flush = Task { await reader.flush() }
        #expect(await readerLifetimeEventually { gate.entered > 0 })
        binding.stop()
        binding.stop()
        var drained = false
        let drain = Task { await lease.effectAuthority.drain(lease.sourceAccessPermit); drained = true }
        await Task.yield()
        #expect(!drained)
        gate.open()
        #expect(await flush.value == .committed)
        await drain.value
        #expect(drained)
        #expect(commits == 1)
    }

    @Test("suspended playback stop publishes its final narration cursor before attachment disposal")
    func terminalNarrationCommitBeforeDisposal() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let environment = ReaderLifetimeEnvironment(fixture: fixture)
        let registeredLease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let effects = TrackingSourceEffects(base: registeredLease.effectAuthority)
        // Preserve the actual registered permit and physical managed borrower,
        // while observing this reader's admissions without closing them.
        let owner = try BookSourceOwner(
            url: registeredLease.url, access: registeredLease.access,
            sourceAccessPermit: registeredLease.sourceAccessPermit, effectAuthority: effects,
            invalidation: registeredLease.owner.invalidation,
            onRelease: { withExtendedLifetime(registeredLease) {} }
        )
        let lease = BookSourceLease(owner: owner, cachePolicy: registeredLease.cachePolicy)
        let reader = fixture.makeReader(lease: lease)
        let gate = ReaderLifetimeGate()
        let cleanup = ReaderSourceInvalidationCleanup()
        let lifecycle = ReaderPositionLifecycleDrain(beginExecution: { _ in {} })
        var published: [Position] = []
        let attachment = ReaderSourceAttachment(
            viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
            playbackOwner: environment.playback, voiceEntry: environment.voice,
            cleanup: cleanup, scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db),
            commit: { position, persist in
                try await persist()
                published.append(position)
                return .committed
            }
        )
        var terminalCallbackSawLiveAttachment = false
        let controller = environment.playback.makeController(
            userId: fixture.owner, bookFileStorage: nil,
            onPersistReadAloudPosition: { locator in
                terminalCallbackSawLiveAttachment = !attachment.isDisposed
                reader.didChangeReadAloudLocation(locator)
                await reader.flush()
            }
        )
        controller.setReadAloudPositionForTests(try ReaderDeletionFixture.locator(0.8))
        reader.didChangeLocation(try ReaderDeletionFixture.locator(0.2))
        var stopCalls = 0
        let close = Task {
            await attachment.close(using: lifecycle, stop: {
                stopCalls += 1
                await gate.wait(cancellationAware: false)
                await controller.stop()
            })
        }
        #expect(await readerLifetimeEventually { gate.entered > 0 })
        #expect(!attachment.isDisposed)
        #expect(published.count == 1)
        #expect(published.first?.percentComplete == 0.2)
        // The binding remains installed, but its initial finite source
        // admission has ended before audio teardown waits.
        #expect(effects.activeCount == 0)
        // drain() is an irreversible revocation boundary, not an observation:
        // use a read-only counter and prove the original permit remains open.
        let probe = try registeredLease.effectAuthority.admit(registeredLease.sourceAccessPermit)
        probe.release()
        let overlap = Task { await attachment.close(using: lifecycle, stop: { stopCalls += 1 }) }
        await Task.yield()
        gate.open()
        #expect(await close.value == .committed)
        #expect(await overlap.value == .committed)
        #expect(stopCalls == 1)
        #expect(terminalCallbackSawLiveAttachment)
        #expect(attachment.isDisposed)
        #expect(effects.activeCount == 0)
        #expect(published.count == 2)
        #expect(published.last?.percentComplete == 0.8)
        let saved = try #require(try await fixture.positions.position(for: fixture.book.id))
        #expect(saved == published.last)
        #expect(try ReaderPositionLocator.decode(jsonString: saved.locator).source == .readAloud)
        controller.dispose()
        cleanup.dispose()
    }

    @Test("ordinary disposal wakes a cleanup awaiting its first registration")
    func disposalWakesReadiness() async {
        let cleanup = ReaderSourceInvalidationCleanup()
        var started = false
        var completed = false
        let work = Task { started = true; await cleanup.perform(); completed = true }
        #expect(await readerLifetimeEventually { started })
        #expect(!completed)
        cleanup.dispose()
        cleanup.dispose()
        let didComplete = await readerLifetimeEventually { completed }
        if !didComplete { work.cancel() }
        #expect(didComplete)
        var called = false
        guard case .disposed = cleanup.register({ called = true }) else {
            Issue.record("Disposed cleanup accepted a late attachment")
            return
        }
        await Task.yield()
        #expect(!called)
    }

    @Test("cleanup disposal joins running actions and drops pending captures")
    func disposalDuringAction() async {
        let cleanup = ReaderSourceInvalidationCleanup()
        let gate = ReaderLifetimeGate()
        var ranSecond = false
        cleanup.register { await gate.wait(cancellationAware: false) }
        cleanup.register { ranSecond = true }
        var firstDone = false
        var joinDone = false
        var joinStarted = false
        let first = Task { await cleanup.perform(); firstDone = true }
        let entered = await readerLifetimeEventually { gate.entered > 0 }
        if !entered { gate.open(); cleanup.dispose() }
        #expect(entered)
        let join = Task { joinStarted = true; await cleanup.perform(); joinDone = true }
        #expect(await readerLifetimeEventually { joinStarted })
        cleanup.dispose()
        #expect(!firstDone)
        #expect(!joinDone)
        gate.open()
        let completed = await readerLifetimeEventually { firstDone && joinDone }
        if !completed { first.cancel(); join.cancel() }
        #expect(completed)
        #expect(!ranSecond)
    }

    @Test("cleanup identities preserve replacement and reentrant actions; late invalidation is inline")
    func cleanupTokensAndLateRegistration() async {
        let cleanup = ReaderSourceInvalidationCleanup()
        var calls: [Int] = []
        guard case .registered(let old) = cleanup.register({ calls.append(0) }) else {
            Issue.record("First cleanup registration was rejected")
            return
        }
        cleanup.unregister(old)
        cleanup.register {
            calls.append(1)
            cleanup.register { calls.append(3) }
        }
        cleanup.register { calls.append(2) }
        cleanup.unregister(old)
        var completed = false
        let task = Task { await cleanup.perform(); completed = true }
        let didComplete = await readerLifetimeEventually { completed }
        if !didComplete { cleanup.dispose(); task.cancel() }
        #expect(didComplete)
        #expect(calls == [1, 2, 3])
        guard case .invalidated = cleanup.register({ calls.append(4) }) else {
            Issue.record("Completed invalidation did not report late registration")
            return
        }
        #expect(calls == [1, 2, 3])
    }

    @Test("actual attachment callback groups read live state and old disposal cannot clear a replacement")
    func attachmentReplacementPreservesCurrentCallbacks() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let environment = ReaderLifetimeEnvironment(fixture: fixture)
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let reader = fixture.makeReader(lease: lease)
        let cleanup = ReaderSourceInvalidationCleanup()
        let poll = ReaderLifetimeGate()
        let old = ReaderSourceAttachment(viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
                                         playbackOwner: environment.playback, voiceEntry: environment.voice,
                                         cleanup: cleanup, scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db))
        await old.registerCleanup()
        #expect(old.installIfCurrent(old, navigation: environment.navigation))
        let replacement = ReaderSourceAttachment(viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
                                                 playbackOwner: environment.playback, voiceEntry: environment.voice,
                                                 cleanup: cleanup, scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db))
        await replacement.registerCleanup()
        #expect(replacement.installIfCurrent(replacement, navigation: environment.navigation))
        old.dispose()
        #expect(reader.onUserNavigation != nil)
        #expect(reader.onUserNavigationForTTSPagePrefetch != nil)
        #expect(reader.onExplicitPageForwardNavigation != nil)
        environment.request = .init(revision: 0, position: "controller-location")
        let locator = try ReaderDeletionFixture.locator()
        environment.following = true
        reader.didChangeLocation(locator)
        #expect(environment.revision == 1)
        #expect(environment.request?.revision == 1)
        environment.following = false
        environment.locked = true
        reader.didChangeLocation(locator)
        #expect(environment.revision == 2)
        environment.locked = false
        reader.didChangeLocation(locator)
        #expect(environment.revision == 2)
        // The callback was installed while readAloud was nil. A controller
        // selected later must be used by the existing production callback.
        let controller = environment.playback.makeController(userId: fixture.owner, bookFileStorage: nil)
        let beforeNavigation = controller.beginUserNavigationIntent().playbackGeneration
        environment.readAloud = controller
        reader.didChangeLocation(locator)
        #expect(await readerLifetimeEventually { controller.playbackGenerationForRecoveryTests > beforeNavigation })
        replacement.dispose()
        #expect(reader.onUserNavigation == nil)
        #expect(reader.onUserNavigationForTTSPagePrefetch == nil)
        #expect(reader.onExplicitPageForwardNavigation == nil)
        reader.didChangeLocation(locator)
        #expect(environment.revision == 2)
        cleanup.dispose()
        poll.open()
        await reader.flush()
        controller.dispose()
        environment.readAloud = nil
    }

    @Test("cancelled setup after a PDF-style suspension cannot resurrect callbacks or polling")
    func cancelledAwaitCannotReinstallAttachment() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let environment = ReaderLifetimeEnvironment(fixture: fixture)
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let reader = fixture.makeReader(lease: lease)
        let cleanup = ReaderSourceInvalidationCleanup()
        let gate = ReaderLifetimeGate()
        let poll = ReaderLifetimeGate()
        let attachment = ReaderSourceAttachment(viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
                                                playbackOwner: environment.playback, voiceEntry: environment.voice,
                                                cleanup: cleanup, scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db))
        var installed = true
        var completed = false
        let setup = Task {
            await attachment.registerCleanup()
            await gate.wait(cancellationAware: false)
            installed = attachment.installIfCurrent(attachment, navigation: environment.navigation)
            completed = true
        }
        let entered = await readerLifetimeEventually { gate.entered > 0 }
        if !entered { gate.open() }
        #expect(entered)
        setup.cancel()
        gate.open()
        let didComplete = await readerLifetimeEventually { completed }
        #expect(didComplete)
        #expect(!installed)
        #expect(reader.onUserNavigation == nil)
        #expect(poll.entered == 0)
        attachment.dispose()
        cleanup.dispose()
        poll.open()
    }

    @Test("a late actual attachment after completed invalidation performs cleanup inline")
    func lateAttachmentAfterInvalidation() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let environment = ReaderLifetimeEnvironment(fixture: fixture)
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let reader = fixture.makeReader(lease: lease)
        let cleanup = ReaderSourceInvalidationCleanup()
        cleanup.register { }
        var completed = false
        let action = Task { await cleanup.perform(); completed = true }
        let didComplete = await readerLifetimeEventually { completed }
        if !didComplete { cleanup.dispose(); action.cancel() }
        #expect(didComplete)
        let attachment = ReaderSourceAttachment(viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
                                                playbackOwner: environment.playback, voiceEntry: environment.voice, cleanup: cleanup, scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db))
        await attachment.registerCleanup()
        #expect(attachment.isDisposed)
        #expect(!attachment.installIfCurrent(attachment, navigation: environment.navigation))
    }
}

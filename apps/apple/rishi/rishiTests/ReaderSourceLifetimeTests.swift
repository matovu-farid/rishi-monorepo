import Foundation
import ReadiumShared
import Testing
@testable import rishi

@Suite("Reader source ownership and attachment teardown")
@MainActor
struct ReaderSourceLifetimeTests {
    @Test("a binding releases its real reader and managed lease while its poll wait is entered")
    func bindingDropsWithoutStop() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let wait = ReaderLifetimeGate()
        var lease: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var reader: ReaderViewModel? = fixture.makeReader(lease: try #require(lease))
        reader?.didChangeLocation(try ReaderDeletionFixture.locator(), isProgrammatic: true)
        await reader?.flush()
        var marked: [BookID] = []
        var binding: ReaderPositionSyncBinding? = ReaderPositionSyncBinding(
            viewModel: try #require(reader), sourceLease: try #require(lease),
            markDirty: { marked.append($0) }, pollWait: { await wait.wait() }
        )
        weak var weakBinding = binding
        weak var weakReader = reader
        weak var weakLease = lease
        let entered = await readerLifetimeEventually { wait.entered > 0 }
        if !entered { binding?.stop(); wait.open() }
        #expect(entered)
        #expect(marked == [fixture.book.id])
        binding = nil
        reader = nil
        lease = nil
        let released = await readerLifetimeEventually { weakBinding == nil && weakReader == nil && weakLease == nil }
        if !released { weakBinding?.stop() }
        wait.open()
        #expect(released)
    }

    @Test("stop is idempotent and an already admitted dirty mark drains before owner release")
    func admittedMarkSurvivesStop() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let mark = ReaderLifetimeGate()
        let wait = ReaderLifetimeGate()
        var lease: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var reader: ReaderViewModel? = fixture.makeReader(lease: try #require(lease))
        reader?.didChangeLocation(try ReaderDeletionFixture.locator(), isProgrammatic: true)
        await reader?.flush()
        var marks = 0
        var binding: ReaderPositionSyncBinding? = ReaderPositionSyncBinding(
            viewModel: try #require(reader), sourceLease: try #require(lease),
            markDirty: { _ in marks += 1; await mark.wait(cancellationAware: false) },
            pollWait: { await wait.wait() }
        )
        weak var weakBinding = binding
        weak var weakReader = reader
        weak var weakLease = lease
        let entered = await readerLifetimeEventually { mark.entered > 0 }
        if !entered { mark.open(); binding?.stop() }
        #expect(entered)
        let authority = try #require(lease).effectAuthority
        let permit = try #require(lease).sourceAccessPermit
        binding?.stop()
        binding?.stop()
        reader?.didChangeLocation(try ReaderDeletionFixture.locator(0.7), isProgrammatic: true)
        await reader?.flush()
        var drainStarted = false
        var drained = false
        let drain = Task { drainStarted = true; await authority.drain(permit); drained = true }
        #expect(await readerLifetimeEventually { drainStarted })
        #expect(!drained)
        binding = nil
        reader = nil
        lease = nil
        #expect(weakBinding != nil)
        #expect(weakReader != nil)
        #expect(weakLease != nil)
        mark.open()
        wait.open()
        let completed = await readerLifetimeEventually { drained && weakBinding == nil && weakReader == nil && weakLease == nil }
        if !completed { drain.cancel() }
        #expect(completed)
        #expect(marks == 1)
        #expect(wait.entered == 0)
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
                                         cleanup: cleanup, pollWait: { await poll.wait() })
        await old.registerCleanup()
        #expect(old.installIfCurrent(old, navigation: environment.navigation))
        let replacement = ReaderSourceAttachment(viewModel: reader, sourceLease: lease, syncEngine: fixture.sync,
                                                 playbackOwner: environment.playback, voiceEntry: environment.voice,
                                                 cleanup: cleanup, pollWait: { await poll.wait() })
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
                                                cleanup: cleanup, pollWait: { await poll.wait() })
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
                                                playbackOwner: environment.playback, voiceEntry: environment.voice, cleanup: cleanup)
        await attachment.registerCleanup()
        #expect(attachment.isDisposed)
        #expect(!attachment.installIfCurrent(attachment, navigation: environment.navigation))
    }
}

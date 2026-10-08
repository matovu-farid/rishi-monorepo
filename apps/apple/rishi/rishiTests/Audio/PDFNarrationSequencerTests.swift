import Foundation
import ReadiumShared
import Testing
@testable import rishi

@Suite("PDF narration relative sequencing", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct PDFNarrationSequencerTests {
    @MainActor private final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var entered = false
        func wait() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            // Deliberately completes after cancellation to exercise stale work.
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilEntered() async {
            guard !entered else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { entryWaiter = continuation }
                }
            } onCancel: {
                Task { @MainActor in self.entryWaiter?.resume(); self.entryWaiter = nil }
            }
        }
        func open() { waiter?.resume(); waiter = nil }
    }

    @MainActor private final class Owner {
        var token = UUID()
        var generation: UInt64 = 1
        var native = NSObject()
        var retainedIdentities: [NSObject] = []
        let locator: Locator
        var lookups: [(PDFNarrationCursor, Int)] = []
        var applied: [PDFNarrationCursor] = []
        var checkedIDs: [ObjectIdentifier] = []
        var stopped: [RemoteCommandLease?] = []
        var resolveOverride: (@MainActor (PDFNarrationCursor, Int) async -> PDFNarrationTarget?)?
        var shouldApply = true
        var onApply: (@MainActor () -> Void)?
        var onStop: (@MainActor () -> Void)?

        init() throws {
            locator = Locator(href: try #require(RelativeURL(path: "sequencer.pdf")), mediaType: .pdf)
        }
        func request(_ delta: Int, lease: RemoteCommandLease? = nil) -> PDFNarrationSkipRequest {
            .init(delta: delta, playbackToken: token, playbackGeneration: generation, lease: lease)
        }
        func target(_ cursor: PDFNarrationCursor, _ delta: Int) -> PDFNarrationTarget {
            .init(page: cursor.page, ordinal: cursor.ordinal + delta, paragraphStart: 100, locator: locator)
        }
        func isCurrent(_ request: PDFNarrationSkipRequest, _ expectedID: ObjectIdentifier) -> Bool {
            checkedIDs.append(expectedID)
            return request.playbackToken == token && request.playbackGeneration == generation
                && ObjectIdentifier(native) == expectedID && (request.lease?.isValid ?? true)
        }
        func resolve(_ cursor: PDFNarrationCursor, _ delta: Int) async -> PDFNarrationTarget? {
            lookups.append((cursor, delta))
            if let resolveOverride { return await resolveOverride(cursor, delta) }
            return target(cursor, delta)
        }
        func apply(_ target: PDFNarrationTarget, _ expectedID: ObjectIdentifier) -> ObjectIdentifier? {
            guard shouldApply, ObjectIdentifier(native) == expectedID else { return nil }
            applied.append(.init(page: target.page, ordinal: target.ordinal))
            retainedIdentities.append(native) // Prevent ObjectIdentifier reuse in the fixture.
            native = NSObject()
            onApply?()
            return ObjectIdentifier(native)
        }
        func stop(_ lease: RemoteCommandLease?) {
            stopped.append(lease)
            onStop?()
        }
        func sequencer() -> PDFNarrationSequencer {
            PDFNarrationSequencer(
                isCurrent: { [weak self] request, id in self?.isCurrent(request, id) ?? false },
                resolve: { [weak self] cursor, delta in await self?.resolve(cursor, delta) },
                apply: { [weak self] target, id in self?.apply(target, id) },
                stopAtEnd: { [weak self] lease in self?.stop(lease) }
            )
        }
        func enqueue(_ delta: Int, on sequencer: PDFNarrationSequencer, cursor: PDFNarrationCursor? = .init(page: 1, ordinal: 0), lease: RemoteCommandLease? = nil) {
            sequencer.enqueue(request(delta, lease: lease), initialCursor: cursor, synthesizerID: ObjectIdentifier(native))
        }
    }

    private func lease() -> RemoteCommandLease {
        .init(processSessionID: UUID(), accountGeneration: 1, playbackGeneration: 1)
    }

    @Test("three nexts use successive logical cursors and replacement identities")
    func repeatedNext() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        let firstID = ObjectIdentifier(owner.native)
        for _ in 0..<3 { owner.enqueue(1, on: sequencer) }
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.map { $0.0.ordinal } == [0, 1, 2])
        #expect(owner.applied.map(\.ordinal) == [1, 2, 3])
        #expect(owner.retainedIdentities.count == 3)
        #expect(owner.checkedIDs == owner.retainedIdentities.flatMap { [ObjectIdentifier($0), ObjectIdentifier($0)] })
        #expect(owner.checkedIDs.first == firstID)
        #expect(owner.stopped.isEmpty)
    }

    @Test("mixed directions retain FIFO across pages")
    func mixedDirections() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.resolveOverride = { [weak owner] cursor, delta in
            guard let owner else { return nil }
            if cursor.page == 1 && cursor.ordinal == 1 && delta == 1 {
                return owner.target(.init(page: 2, ordinal: -1), 1)
            }
            if cursor.page == 2 && cursor.ordinal == 0 && delta == -1 {
                return owner.target(.init(page: 1, ordinal: 2), -1)
            }
            return owner.target(cursor, delta)
        }
        for delta in [1, 1, -1, -1] { owner.enqueue(delta, on: sequencer) }
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.map { $0.1 } == [1, 1, -1, -1])
        #expect(owner.applied == [.init(page: 1, ordinal: 1), .init(page: 2, ordinal: 0), .init(page: 1, ordinal: 1), .init(page: 1, ordinal: 0)])
    }

    @Test("missing cursor, invalid delta and revoked lease reject admission", arguments: ["cursor", "delta", "lease"])
    func rejectedAdmission(_ kind: String) async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        let lease = lease()
        if kind == "lease" { lease.revoke() }
        owner.enqueue(kind == "delta" ? 0 : 1, on: sequencer, cursor: kind == "cursor" ? nil : .init(page: 1, ordinal: 0), lease: lease)
        #expect(sequencer.currentDrainCompletion() == nil)
        #expect(owner.lookups.isEmpty && owner.applied.isEmpty)
        owner.enqueue(1, on: sequencer)
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.applied == [.init(page: 1, ordinal: 1)])
    }

    @Test("live lease, token, generation and native ownership are checked after lookup", arguments: ["lease", "token", "generation", "native"])
    func suspendedInvalidation(_ kind: String) async throws {
        let owner = try Owner(), sequencer = owner.sequencer(), gate = Gate()
        defer { gate.open(); sequencer.cancel() }
        let lease = lease()
        owner.resolveOverride = { [weak owner] cursor, delta in
            await gate.wait()
            return owner?.target(cursor, delta)
        }
        owner.enqueue(1, on: sequencer, lease: lease)
        await gate.waitUntilEntered()
        switch kind {
        case "lease": lease.revoke()
        case "token": owner.token = UUID()
        case "generation": owner.generation += 1
        default: owner.retainedIdentities.append(owner.native); owner.native = NSObject()
        }
        let completion = sequencer.currentDrainCompletion()
        gate.open()
        await completion?.value
        #expect(owner.lookups.count == 1)
        #expect(owner.applied.isEmpty && owner.stopped.isEmpty)
    }

    @Test("stale queued requests skip lookup and allow a fresh request")
    func invalidBeforeLookup() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.enqueue(1, on: sequencer)
        owner.token = UUID()
        owner.enqueue(1, on: sequencer)
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.count == 1)
        #expect(owner.applied == [.init(page: 1, ordinal: 1)])
    }

    @Test("old suspended completion cannot clear or overwrite a replacement worker")
    func cancelThenRestart() async throws {
        let owner = try Owner(), sequencer = owner.sequencer(), oldGate = Gate(), newGate = Gate()
        defer { oldGate.open(); newGate.open(); sequencer.cancel() }
        owner.resolveOverride = { [weak owner] cursor, delta in
            if cursor.page == 1 { await oldGate.wait() }
            else if cursor.ordinal == 0 { await newGate.wait() }
            return owner?.target(cursor, delta)
        }
        owner.enqueue(1, on: sequencer)
        await oldGate.waitUntilEntered()
        let oldCompletion = sequencer.currentDrainCompletion()
        sequencer.cancel()
        owner.enqueue(1, on: sequencer, cursor: .init(page: 2, ordinal: 0))
        await newGate.waitUntilEntered()
        let newCompletion = sequencer.currentDrainCompletion()
        oldGate.open()
        await oldCompletion?.value
        #expect(owner.applied.isEmpty && owner.stopped.isEmpty)
        // Nil cursor works only if the new worker survived the old defer.
        owner.enqueue(1, on: sequencer, cursor: nil)
        newGate.open()
        await newCompletion?.value
        #expect(owner.applied == [.init(page: 2, ordinal: 1), .init(page: 2, ordinal: 2)])
        #expect(owner.lookups.map { $0.0.page } == [1, 2, 2])
    }

    @Test("synchronous apply cancellation cannot resume the old drain")
    func applyCancels() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.onApply = { sequencer.cancel() }
        owner.enqueue(1, on: sequencer)
        owner.enqueue(1, on: sequencer)
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.applied == [.init(page: 1, ordinal: 1)])
        #expect(owner.lookups.count == 1)
        owner.onApply = nil
        owner.enqueue(1, on: sequencer, cursor: .init(page: 1, ordinal: 5))
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.applied.last == .init(page: 1, ordinal: 6))
    }

    @Test("apply may cancel and enqueue a new worker without old identity overwrite")
    func applyRestarts() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.onApply = { [weak owner] in
            sequencer.cancel()
            owner?.onApply = nil
            owner?.enqueue(1, on: sequencer, cursor: .init(page: 2, ordinal: 10))
        }
        owner.enqueue(1, on: sequencer)
        owner.enqueue(1, on: sequencer)
        let oldCompletion = sequencer.currentDrainCompletion()
        await oldCompletion?.value
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.applied == [.init(page: 1, ordinal: 1), .init(page: 2, ordinal: 11)])
        #expect(owner.lookups.count == 2)
    }

    @Test("forward exhaustion stops once with its original lease and clears through the owner")
    func forwardExhaustion() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        let lease = lease()
        owner.resolveOverride = { _, _ in nil }
        owner.onStop = { sequencer.cancel() }
        owner.enqueue(1, on: sequencer, lease: lease)
        owner.enqueue(1, on: sequencer, lease: self.lease())
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.count == 1 && owner.applied.isEmpty)
        #expect(owner.stopped.count == 1)
        #expect(owner.stopped[0] === lease)
    }

    @Test("backward exhaustion preserves remaining FIFO steps until the next enqueue")
    func backwardExhaustion() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.resolveOverride = { _, _ in nil }
        for delta in [-1, 1, 1] { owner.enqueue(delta, on: sequencer) }
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.stopped.isEmpty && owner.applied.isEmpty)
        owner.resolveOverride = nil
        owner.enqueue(-1, on: sequencer, cursor: .init(page: 3, ordinal: 10))
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.map { $0.1 } == [-1, 1, 1, -1])
        #expect(owner.applied == [.init(page: 3, ordinal: 11), .init(page: 3, ordinal: 12), .init(page: 3, ordinal: 11)])
    }

    @Test("failed replacement preserves remaining FIFO steps until the next enqueue")
    func failedApply() async throws {
        let owner = try Owner(), sequencer = owner.sequencer()
        defer { sequencer.cancel() }
        owner.shouldApply = false
        for delta in [1, -1, 1] { owner.enqueue(delta, on: sequencer) }
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.count == 1 && owner.applied.isEmpty && owner.stopped.isEmpty)
        owner.shouldApply = true
        owner.enqueue(1, on: sequencer, cursor: .init(page: 1, ordinal: 10))
        await sequencer.currentDrainCompletion()?.value
        #expect(owner.lookups.map { $0.1 } == [1, -1, 1, 1])
        #expect(owner.applied.map(\.ordinal) == [9, 10, 11])
    }

    @Test("missing weak owner suppresses all effects")
    func missingOwner() async throws {
        var owner: Owner? = try Owner()
        weak let weakOwner = owner
        let sequencer = try #require(owner).sequencer()
        defer { sequencer.cancel() }
        owner?.enqueue(1, on: sequencer)
        owner = nil
        #expect(weakOwner == nil)
        await sequencer.currentDrainCompletion()?.value
        #expect(sequencer.currentDrainCompletion() == nil)
    }
}

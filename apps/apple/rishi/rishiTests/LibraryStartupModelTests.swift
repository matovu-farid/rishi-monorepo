import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Account-owned library startup")
struct LibraryStartupModelTests {
    @Test("Native initial read, sync, post-sync read and prewarm keep their order")
    func initialOrder() async throws {
        let fixture = StartupFixture()
        await fixture.model.load(consentGranted: true, autoSync: true)
        #expect(await fixture.store.events == ["read", "sync", "read", "prewarm"])
        #expect(fixture.effects.syncCount == 1)
        #expect(fixture.effects.prewarmCount == 1)
        #expect(fixture.library.loadReadiness == .success(fixture.identity))
        let intent = try #require(fixture.model.intent)
        #expect(intent.identity == fixture.identity)
        #expect(intent.kind == .firstBookPrompt)
        #expect(!intent.markFirstBookPromptSeen)
    }

    @Test("Consent and autoSync independently gate sync without blocking local readiness", arguments: [true, false])
    func noSync(_ autoSync: Bool) async {
        let fixture = StartupFixture()
        await fixture.model.load(consentGranted: !autoSync, autoSync: autoSync)
        #expect(await fixture.store.events == ["read", "prewarm"])
        #expect(fixture.effects.syncCount == 0)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
    }

    @Test("A failed initial read publishes neither prompt nor trial and retry uses a fresh attempt")
    func initialFailureAndRetry() async throws {
        let fixture = StartupFixture()
        await fixture.store.setAction(.fail, read: 1)
        await fixture.model.load(consentGranted: true, autoSync: true)
        let failedID = try #require(fixture.model.currentAttemptID)
        #expect(fixture.library.loadReadiness == .failure(fixture.identity))
        #expect(fixture.model.intent == nil)
        #expect(fixture.effects.syncCount == 0)
        #expect(fixture.effects.prewarmCount == 0)
        #expect(!fixture.model.isCurrentAttempt(UUID()))
        await fixture.model.load(consentGranted: false, autoSync: true)
        #expect(fixture.model.currentAttemptID != failedID)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
    }

    @Test("Matching completion during suspended post-sync read never starts a competing refresh")
    func earlyCompletion() async throws {
        let fixture = StartupFixture()
        let gate = StartupGate()
        defer { gate.open() }
        await fixture.store.setAction(.pause(gate, false), read: 2)
        let load = Task { await fixture.model.load(consentGranted: true, autoSync: true) }
        defer { load.cancel() }
        try #require(await gate.waitForEntry())
        await fixture.model.syncCompleted(waveID: fixture.effects.waveID)
        #expect(await fixture.store.readCount == 2)
        #expect(fixture.model.intent == nil)
        gate.open()
        await load.value
        #expect(await fixture.store.readCount == 2)
        #expect(fixture.effects.prewarmCount == 1)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
        await fixture.model.syncCompleted(waveID: fixture.effects.waveID)
        #expect(await fixture.store.readCount == 2)
        await fixture.model.syncCompleted(waveID: UUID())
        #expect(await fixture.store.readCount == 3)
        #expect(fixture.effects.prewarmCount == 2)
    }

    @Test("Failed post-sync read retains one fallback for early or delayed completion", arguments: [true, false])
    func failedPostSyncRead(_ early: Bool) async throws {
        let fixture = StartupFixture()
        let gate = StartupGate()
        defer { gate.open() }
        await fixture.store.setAction(early ? .pause(gate, true) : .fail, read: 2)
        let load = Task { await fixture.model.load(consentGranted: true, autoSync: true) }
        defer { load.cancel() }
        if early {
            try #require(await gate.waitForEntry())
            await fixture.model.syncCompleted(waveID: fixture.effects.waveID)
            gate.open()
        }
        await load.value
        if !early {
            #expect(fixture.model.intent == nil)
            await fixture.model.syncCompleted(waveID: fixture.effects.waveID)
        }
        #expect(await fixture.store.readCount == 3)
        #expect(fixture.effects.prewarmCount == 1)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
        await fixture.model.syncCompleted(waveID: fixture.effects.waveID)
        #expect(await fixture.store.readCount == 3)
    }

    @Test("Same-account retry supersedes a suspended old prewarm and its completion")
    func sameAccountRetry() async throws {
        let fixture = StartupFixture()
        let gate = StartupGate()
        fixture.effects.prewarmGate = gate
        defer { gate.open() }
        let old = Task { await fixture.model.load(consentGranted: false, autoSync: true) }
        defer { old.cancel() }
        try #require(await gate.waitForEntry())
        let oldID = try #require(fixture.model.currentAttemptID)
        await fixture.model.load(consentGranted: false, autoSync: true)
        let current = try #require(fixture.model.intent)
        #expect(current.attemptID != oldID)
        gate.open()
        await old.value
        #expect(fixture.model.intent?.id == current.id)
        #expect(fixture.model.takeIntent(id: current.id)?.id == current.id)
        #expect(fixture.model.takeIntent(id: current.id) == nil)
    }

    @Test("A generation change, cancellation or retirement during prewarm cannot publish readiness", arguments: ["generation", "cancel", "retire"])
    func stalePrewarm(_ kind: String) async throws {
        let fixture = StartupFixture()
        let gate = StartupGate()
        fixture.effects.prewarmGate = gate
        defer { gate.open() }
        let load = Task { await fixture.model.load(consentGranted: false, autoSync: true) }
        defer { load.cancel() }
        try #require(await gate.waitForEntry())
        switch kind {
        case "generation": fixture.current.value = .init(userID: fixture.identity.userID, generation: fixture.identity.generation + 1)
        case "cancel": load.cancel()
        default: fixture.model.retire()
        }
        gate.open()
        await load.value
        #expect(fixture.model.intent == nil)
        #expect(await fixture.store.readCount == 1)
        if kind == "retire" {
            await fixture.model.load(consentGranted: false, autoSync: true)
            #expect(await fixture.store.readCount == 1)
        }
    }

    @Test("Post-prewarm failed readiness is revalidated and recovered by a later successful snapshot")
    func postPrewarmSnapshotFailure() async throws {
        let fixture = StartupFixture()
        let gate = StartupGate()
        fixture.effects.prewarmGate = gate
        defer { gate.open() }
        let load = Task { await fixture.model.load(consentGranted: false, autoSync: true) }
        defer { load.cancel() }
        try #require(await gate.waitForEntry())
        await fixture.store.setAction(.fail, read: 2)
        await fixture.store.setAction(.fail, read: 3)
        #expect(await fixture.library.refresh() == .failure)
        gate.open()
        await load.value
        #expect(fixture.model.intent == nil)
        #expect(await fixture.store.readCount == 3)
        #expect(await fixture.library.refresh() == .success)
        await fixture.model.snapshotReadinessChanged(fixture.library.loadReadiness)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
        #expect(fixture.effects.prewarmCount == 2)
    }

    @Test("Initial failure recovers from authoritative import snapshot readiness")
    func readinessAfterFailedInitialRead() async {
        let fixture = StartupFixture()
        await fixture.store.setAction(.fail, read: 1)
        await fixture.model.load(consentGranted: false, autoSync: false)
        #expect(fixture.model.intent == nil)
        #expect(await fixture.library.refresh() == .success)
        await fixture.model.snapshotReadinessChanged(fixture.library.loadReadiness)
        #expect(fixture.model.intent?.kind == .firstBookPrompt)
        #expect(fixture.effects.prewarmCount == 1)
    }

    @Test("Recovered first-book choice precedes ordinary prompt and trial readiness")
    func recoveryFirst() async throws {
        let fixture = StartupFixture()
        fixture.model.updateFirstBookFacts(.init(hasSeenPrompt: true, recoveryPending: true,
            documentPickerPresented: false, firstPromptImportActive: false))
        await fixture.model.load(consentGranted: false, autoSync: true)
        let current = try #require(fixture.model.intent)
        #expect(current.kind == .recoveryPrompt)
        #expect(!current.markFirstBookPromptSeen)
        #expect(fixture.model.takeIntent(id: UUID()) == nil)
        #expect(fixture.model.takeIntent(id: current.id)?.id == current.id)
        #expect(fixture.model.takeIntent(id: current.id) == nil)
    }

    @Test("Seen or populated libraries emit a current trial intent and only populated unseen libraries request the seen marker", arguments: [true, false])
    func trialIntent(_ seen: Bool) async throws {
        let fixture = StartupFixture()
        if !seen { try await fixture.store.upsert(.fixture(userId: fixture.identity.userID)) }
        fixture.model.updateFirstBookFacts(.init(hasSeenPrompt: seen, recoveryPending: false,
            documentPickerPresented: false, firstPromptImportActive: false))
        await fixture.model.load(consentGranted: false, autoSync: true)
        let intent = try #require(fixture.model.intent)
        #expect(intent.kind == .trialReady)
        #expect(intent.markFirstBookPromptSeen == !seen)
        fixture.current.value = .init(userID: fixture.identity.userID, generation: fixture.identity.generation + 1)
        #expect(fixture.model.takeIntent(id: intent.id) == nil)
    }

    @Test("Dismissal revalidation queues trial until both picker and import blockers clear")
    func pickerAndImportDeferral() async throws {
        let fixture = StartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let prompt = try #require(fixture.model.intent)
        #expect(fixture.model.takeIntent(id: prompt.id)?.kind == .firstBookPrompt)
        var facts = LibraryStartupModel.FirstBookFacts(hasSeenPrompt: false, recoveryPending: true,
            documentPickerPresented: true, firstPromptImportActive: true)
        fixture.model.updateFirstBookFacts(facts)
        #expect(await fixture.model.requestTrialReadiness())
        #expect(fixture.model.intent == nil)
        facts.documentPickerPresented = false
        fixture.model.updateFirstBookFacts(facts)
        #expect(fixture.model.intent == nil)
        facts.firstPromptImportActive = false
        fixture.model.updateFirstBookFacts(facts)
        let ready = try #require(fixture.model.intent)
        #expect(ready.kind == .trialReady)
        #expect(!ready.markFirstBookPromptSeen, "Skipping a saved first-book choice must not mark it seen")
        #expect(fixture.model.takeIntent(id: ready.id)?.kind == .trialReady)
        fixture.model.updateFirstBookFacts(facts)
        #expect(fixture.model.intent == nil)
    }

    @Test("Consent reload preserves an admitted blocked trial request and its seen marker until fresh readiness", arguments: [true, false])
    func queuedTrialSurvivesReload(_ seen: Bool) async throws {
        let fixture = StartupFixture()
        if !seen { try await fixture.store.upsert(.fixture(userId: fixture.identity.userID)) }
        var facts = LibraryStartupModel.FirstBookFacts(hasSeenPrompt: seen, recoveryPending: false,
            documentPickerPresented: true, firstPromptImportActive: true)
        fixture.model.updateFirstBookFacts(facts)
        await fixture.model.load(consentGranted: false, autoSync: false)
        let originalAttempt = try #require(fixture.model.currentAttemptID)
        #expect(fixture.model.intent == nil)
        // Appearance refresh reuses a successful snapshot. Force an actual
        // public mutation refresh failure so the reload must read again.
        await fixture.store.setAction(.fail, read: 2)
        #expect(await fixture.library.refresh() == .failure)
        #expect(fixture.library.loadReadiness == .failure(fixture.identity))
        let readGate = StartupGate()
        defer { readGate.open() }
        await fixture.store.setAction(.pause(readGate, false), read: 3)
        let reload = Task { await fixture.model.load(consentGranted: true, autoSync: false) }
        defer { reload.cancel() }
        try #require(await readGate.waitForEntry())
        #expect(!fixture.model.isCurrentAttempt(originalAttempt))
        facts.documentPickerPresented = false
        fixture.model.updateFirstBookFacts(facts)
        #expect(fixture.model.intent == nil)
        facts.firstPromptImportActive = false
        fixture.model.updateFirstBookFacts(facts)
        #expect(fixture.model.intent == nil, "The original successful snapshot cannot admit the replacement attempt")
        readGate.open()
        await reload.value
        let ready = try #require(fixture.model.intent)
        #expect(ready.kind == .trialReady)
        #expect(ready.identity == fixture.identity)
        #expect(ready.attemptID != originalAttempt)
        #expect(fixture.model.isCurrentAttempt(ready.attemptID))
        #expect(ready.markFirstBookPromptSeen == !seen)
        #expect(fixture.library.loadReadiness == .success(fixture.identity))
        #expect(await fixture.store.readCount == 3)
        #expect(fixture.effects.syncCount == 0)
        #expect(fixture.model.takeIntent(id: ready.id)?.id == ready.id)
        #expect(fixture.model.takeIntent(id: ready.id) == nil)
        fixture.model.updateFirstBookFacts(facts)
        #expect(fixture.model.intent == nil)
        await fixture.model.load(consentGranted: false, autoSync: false)
        #expect(fixture.model.intent == nil, "A consumed trial request must not replay on another consent change")
    }

    @Test("Superseded queued picker work cannot use readiness from a same-account replacement attempt")
    func deferredPickerSuperseded() async throws {
        let fixture = StartupFixture()
        await fixture.model.load(consentGranted: false, autoSync: true)
        let prompt = try #require(fixture.model.intent)
        _ = fixture.model.takeIntent(id: prompt.id)
        await fixture.store.setAction(.fail, read: 2)
        #expect(await fixture.library.refresh() == .failure)
        let readGate = StartupGate()
        let beginGate = StartupGate()
        defer { readGate.open(); beginGate.open() }
        await fixture.store.setAction(.pause(readGate, false), read: 3)
        let oldID = try #require(fixture.model.currentAttemptID)
        let request = Task { await fixture.model.requestTrialReadiness() }
        defer { request.cancel() }
        try #require(await readGate.waitForEntry())
        fixture.effects.prepareGate = beginGate
        let replacement = Task { await fixture.model.load(consentGranted: false, autoSync: false) }
        defer { replacement.cancel() }
        try #require(await beginGate.waitForEntry())
        #expect(!fixture.model.isCurrentAttempt(oldID))
        readGate.open()
        #expect(await request.value == false)
        beginGate.open()
        await replacement.value
        #expect(fixture.model.intent == nil)
    }
}

@MainActor
private final class StartupCurrentIdentity {
    var value: LibraryAccountIdentity?
    init(_ value: LibraryAccountIdentity) { self.value = value }
}

@MainActor
private final class StartupEffects {
    let waveID = UUID()
    var syncCount = 0
    var prewarmCount = 0
    var prewarmGate: StartupGate?
    var prepareGate: StartupGate?
}

@MainActor
private final class StartupFixture {
    let identity = LibraryAccountIdentity(userID: UUID(), generation: 41)
    let current: StartupCurrentIdentity
    let effects: StartupEffects
    let store: StartupBookStore
    let library: LibraryViewModel
    let model: LibraryStartupModel

    init() {
        let current = StartupCurrentIdentity(identity)
        let effects = StartupEffects()
        let store = StartupBookStore()
        self.current = current; self.effects = effects; self.store = store
        let storage = BookFileStorage(rootURL: .temporaryDirectory.appendingPathComponent("Startup-\(UUID())"), bookStore: store, coverExtractors: [:])
        // These startup cases never import; the importer is bound to the
        // immutable original fixture owner rather than reading UI state.
        let importerOwnerID = identity.userID
        let library = LibraryViewModel(bookStore: store, currentUserId: { current.value?.userID },
            boundAccountIdentity: identity, currentAccountIdentity: { current.value },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { importerOwnerID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }), deleteBook: { _ in })
        self.library = library
        self.model = LibraryStartupModel(identity: identity, library: library, currentIdentity: { current.value },
            sync: { onWaveID in
                effects.syncCount += 1
                await store.record("sync")
                await onWaveID(effects.waveID)
            },
            prewarm: { _ in
                effects.prewarmCount += 1
                await store.record("prewarm")
                let gate = effects.prewarmGate
                effects.prewarmGate = nil
                _ = await gate?.pause()
            },
            prepareInitialSnapshot: {
                let gate = effects.prepareGate
                effects.prepareGate = nil
                _ = await gate?.pause()
            })
    }
}

private enum StartupReadFailure: Error { case failed }

private actor StartupBookStore: BookStore {
    enum Action: Sendable { case fail, pause(StartupGate, Bool) }
    private let memory = InMemoryBookStore()
    private var actions: [Int: Action] = [:]
    private(set) var readCount = 0
    private(set) var events: [String] = []
    func setAction(_ action: Action, read: Int) { actions[read] = action }
    func record(_ value: String) { events.append(value) }
    func books(for userId: UserID) async throws -> [Book] {
        readCount += 1
        events.append("read")
        if let action = actions.removeValue(forKey: readCount) {
            switch action {
            case .fail: throw StartupReadFailure.failed
            case .pause(let gate, let fail):
                guard await gate.pause(), !fail else { throw StartupReadFailure.failed }
                try Task.checkCancellation()
            }
        }
        return try await memory.books(for: userId)
    }
    func book(_ id: BookID) async throws -> Book? { try await memory.book(id) }
    func upsert(_ book: Book) async throws { try await memory.upsert(book) }
    func delete(_ id: BookID) async throws { try await memory.delete(id) }
    func deleteIfUnchanged(_ id: BookID, matching expected: Book?) async throws -> Bool {
        try await memory.deleteIfUnchanged(id, matching: expected)
    }
}

/// Timeouts bound a broken fixture; successful ordering uses continuations only.
@MainActor
private final class StartupGate {
    private var entered = false
    private var released = false
    private var timedOut = false
    private var entries: [CheckedContinuation<Bool, Never>] = []
    private var releases: [CheckedContinuation<Bool, Never>] = []
    private var timeout: Task<Void, Never>?

    func waitForEntry() async -> Bool {
        if entered { return true }
        if released { return false }
        return await withCheckedContinuation { continuation in
            entries.append(continuation)
            startTimeout()
        }
    }
    func pause() async -> Bool {
        entered = true
        let waiting = entries
        entries.removeAll()
        waiting.forEach { $0.resume(returning: true) }
        if released { return !timedOut }
        return await withCheckedContinuation { continuation in
            releases.append(continuation)
            startTimeout()
        }
    }
    func open() {
        guard !released else { return }
        released = true
        timeout?.cancel()
        timeout = nil
        let waiting = releases
        releases.removeAll()
        waiting.forEach { $0.resume(returning: !timedOut) }
        let entering = entries
        entries.removeAll()
        entering.forEach { $0.resume(returning: entered) }
    }
    private func startTimeout() {
        guard timeout == nil else { return }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.timedOut = true
            self.open()
            Issue.record("Library startup fixture gate timed out")
        }
    }
}

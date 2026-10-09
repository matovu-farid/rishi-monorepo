import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Incoming book coordinator presentation")
struct IncomingBookFileCoordinatorPresentationTests {
    @Test("import survives host removal and opens from another ready host")
    func importHandoff() async throws {
        let f = try PresentationFixture()
        let first = f.readyHost(), second = f.readyHost()
        let gate = AsyncGate()
        let calls = PresentationCalls()
        let book = f.book
        f.register(first, calls: calls, book: book, importGate: gate)
        #expect(f.coordinator.receive(f.source, sceneID: first.id, identity: f.identity) == .accepted)
        await calls.waitForImport()
        f.coordinator.unregisterScene(id: first.id)
        f.register(second, calls: calls, book: book)
        gate.open()
        await settlePresentation { calls.openCount == 1 }
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 1)
    }

    @Test("blocker appearing during import retains the book until readiness clears")
    func blockerAfterImport() async throws {
        let f = try PresentationFixture(), host = f.readyHost()
        let gate = AsyncGate(), calls = PresentationCalls()
        f.register(host, calls: calls, book: f.book, importGate: gate)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await calls.waitForImport()
        host.readiness.report(.libraryRoot, identity: f.identity, blockers: [.activeImport])
        gate.open()
        await settlePresentation { calls.refreshCount == 1 }
        #expect(calls.openCount == 0)
        #expect(f.coordinator.hasPendingFile(for: f.identity))
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .duplicate)
        host.readiness.report(.libraryRoot, identity: f.identity, blockers: [])
        f.coordinator.requestDrain()
        await settlePresentation { calls.openCount == 1 }
        #expect(calls.importCount == 1)
        #expect(!f.coordinator.hasPendingFile(for: f.identity))
    }

    @Test("successful import supersedes the queued prompt even when presentation expires")
    func successfulImportSupersedesPromptBeforePresentation() async throws {
        let startup = IncomingStartupFixture()
        await startup.model.load(consentGranted: false, autoSync: true)
        let intent = try #require(startup.model.intent)
        let attemptID = try #require(startup.model.currentAttemptID)
        #expect(intent.kind == .firstBookPrompt)

        let f = try PresentationFixture(identity: startup.identity, readyLifetime: .seconds(5))
        let host = f.readyHost(), calls = PresentationCalls(), importGate = AsyncGate()
        f.register(
            host,
            calls: calls,
            book: f.book,
            importGate: importGate,
            importAttemptID: { attemptID },
            didImportSuccessfully: { book, identity, capturedAttempt in
                guard identity == startup.identity,
                      book.userId == identity.userID,
                      capturedAttempt == attemptID,
                      startup.model.isCurrentAttempt(attemptID) else { return }
                _ = startup.model.supersedeFirstBookIntent(identity: identity, attemptID: attemptID)
            }
        )
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: startup.identity) == .accepted)
        await calls.waitForImport()
        host.readiness.report(.libraryRoot, identity: startup.identity, blockers: [.activeImport])
        importGate.open()
        await settlePresentation { calls.refreshCount == 1 }
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 0)
        #expect(startup.model.intent == nil)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: startup.identity) == .duplicate)

        f.clock.advance(by: .seconds(5))
        await settlePresentation { f.coordinator.presentationError != nil }
        #expect(calls.openCount == 0)
        f.coordinator.dismissError()
        #expect(startup.model.intent == nil)
        #expect(startup.model.takeIntent(id: intent.id) == nil)
    }

    @Test("global error gates another scene until dismissed")
    func globalErrorGate() async throws {
        let f = try PresentationFixture(), first = f.readyHost(), second = f.readyHost()
        let calls = PresentationCalls()
        f.coordinator.registerRootScene(id: first.id, isForeground: true)
        f.coordinator.registerRootScene(id: second.id, isForeground: true)
        f.register(second, calls: calls, book: f.book)
        #expect(f.coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: first.id, identity: f.identity) == .unsupported)
        #expect(f.coordinator.selectedRootErrorSceneID == first.id)
        #expect(f.coordinator.receive(f.source, sceneID: second.id, identity: f.identity) == .accepted)
        await settlePresentation()
        #expect(calls.importCount == 0)
        #expect(calls.openCount == 0)
        f.coordinator.dismissError()
        await settlePresentation { calls.openCount == 1 }
        #expect(calls.importCount == 1)
    }

    @Test("active error is revoked when its account changes")
    func accountChangeRevokesActiveError() throws {
        let f = try PresentationFixture()
        let root = UUID()
        f.coordinator.registerRootScene(id: root, isForeground: true)
        #expect(f.coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: root, identity: f.identity) == .unsupported)
        #expect(f.coordinator.presentationError != nil)
        let next = LibraryAccountIdentity(userID: UUID(), generation: 1)
        f.coordinator.accountDidChange(from: f.identity, to: next)
        #expect(f.coordinator.presentationError == nil)
        #expect(f.coordinator.presentationError?.message != "Rishi can open EPUB and PDF files.")
    }

    @Test("accountless invalid input survives first identity resolution")
    func accountlessErrorSurvivesSignIn() throws {
        let f = try PresentationFixture()
        f.coordinator.registerRootScene(id: UUID(), isForeground: true)
        #expect(f.coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: nil, identity: nil) == .unsupported)
        let notice = f.coordinator.presentationError
        f.coordinator.accountDidChange(from: nil, to: f.identity)
        #expect(f.coordinator.presentationError?.id == notice?.id)
    }

    @Test("repeated stale alert dismissal cannot consume promoted notice")
    func staleDismissalDoesNotConsumeNextNotice() throws {
        var limits = IncomingBookFileCoordinator.Limits()
        limits.entries = 0
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try Data("fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let coordinator = IncomingBookFileCoordinator(
            inboxRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            limits: limits
        )
        let root = UUID()
        coordinator.registerRootScene(id: root, isForeground: true)
        _ = coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: root, identity: nil)
        let firstID = coordinator.presentationError!.id
        _ = coordinator.receive(source, sceneID: root, identity: nil)
        coordinator.dismissError(id: firstID)
        let promotedID = coordinator.presentationError?.id
        #expect(promotedID != nil)
        coordinator.dismissError(id: firstID)
        #expect(coordinator.presentationError?.id == promotedID)
    }

    @Test("old host teardown cannot unregister replacement registration")
    func replacementHostSurvivesStaleTeardown() async throws {
        let f = try PresentationFixture(), host = f.readyHost()
        let calls = PresentationCalls()
        let book = f.book
        let oldToken = f.coordinator.registerScene(id: host.id, identity: f.identity, readiness: host.readiness,
            currentIdentity: { f.identity }, prepareForClaim: { true },
            importOwned: { url in calls.imported(); return .init(url: url, book: book, error: nil) },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        let replacementToken = f.coordinator.registerScene(id: host.id, identity: f.identity, readiness: host.readiness,
            currentIdentity: { f.identity }, prepareForClaim: { true },
            importOwned: { url in calls.imported(); return .init(url: url, book: book, error: nil) },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        f.coordinator.unregisterScene(id: host.id, registrationToken: oldToken)
        f.coordinator.setSceneForeground(id: host.id, isForeground: false, registrationToken: oldToken)
        f.coordinator.setSceneForeground(id: host.id, isForeground: true, registrationToken: replacementToken)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        #expect(calls.importCount == 1)
    }

    @Test("idle prompt preclaim still rechecks full readiness")
    func preclaimRecheck() async throws {
        let f = try PresentationFixture(), host = f.readyHost(), calls = PresentationCalls()
        let book = f.book
        host.readiness.report(.libraryTab, identity: f.identity, blockers: [.idleFirstBookPrompt])
        f.coordinator.registerScene(id: host.id, identity: f.identity, readiness: host.readiness,
            currentIdentity: { f.identity }, prepareForClaim: {
                host.readiness.report(.libraryTab, identity: f.identity, blockers: [])
                host.readiness.report(.libraryRoot, identity: f.identity, blockers: [.activeImport])
                return true
            }, importOwned: { url in calls.imported(); return .init(url: url, book: book, error: nil) },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        f.coordinator.setSceneForeground(id: host.id, isForeground: true)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation()
        #expect(calls.importCount == 0)
        #expect(calls.openCount == 0)
        #expect(f.coordinator.hasPendingFile(for: f.identity))
    }

    @Test("ready lifetime begins at import completion without an eligible host")
    func readyDeadline() async throws {
        let f = try PresentationFixture(), clock = f.clock, host = f.readyHost(), calls = PresentationCalls()
        let gate = AsyncGate()
        f.register(host, calls: calls, book: f.book, importGate: gate)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await calls.waitForImport()
        f.coordinator.setSceneForeground(id: host.id, isForeground: false)
        gate.open()
        await settlePresentation { calls.refreshCount == 1 }
        #expect(calls.openCount == 0)
        clock.advance(by: .seconds(60))
        await settlePresentation()
        let root = UUID()
        f.coordinator.registerRootScene(id: root, isForeground: true)
        f.coordinator.foregroundSceneDidActivate()
        #expect(f.coordinator.presentationError?.message == "Book added. Open it from your Library.")
        #expect(calls.openCount == 0)
    }

    @Test("ready expiry notice waits behind active error before another import resumes")
    func readyExpiryNoticeIsQueued() async throws {
        let f = try PresentationFixture(), host = f.readyHost(), calls = PresentationCalls()
        f.register(host, calls: calls, book: f.book, openResult: .unavailable)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        f.coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: host.id, identity: f.identity)
        let secondSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: secondSource) }
        try Data("second".utf8).write(to: secondSource)
        #expect(f.coordinator.receive(secondSource, sceneID: host.id, identity: f.identity) == .accepted)
        f.clock.advance(by: .seconds(60))
        f.coordinator.foregroundSceneDidActivate()
        #expect(f.coordinator.presentationError?.message == "Rishi can open EPUB and PDF files.")
        f.coordinator.dismissError()
        #expect(f.coordinator.presentationError?.message == "Book added. Open it from your Library.")
        #expect(calls.importCount == 1)
        f.coordinator.dismissError()
        await settlePresentation { calls.importCount == 2 }
    }

    @Test("queued book notice is discarded when its account is revoked")
    func queuedNoticeDoesNotCrossAccount() async throws {
        let f = try PresentationFixture(), host = f.readyHost(), calls = PresentationCalls()
        f.register(host, calls: calls, book: f.book, openResult: .unavailable)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        f.coordinator.receive(URL(fileURLWithPath: "/tmp/unsupported.mobi"), sceneID: host.id, identity: f.identity)
        f.clock.advance(by: .seconds(60))
        f.coordinator.foregroundSceneDidActivate()
        #expect(f.coordinator.presentationError?.message == "Rishi can open EPUB and PDF files.")
        f.coordinator.accountDidChange(from: f.identity, to: LibraryAccountIdentity(userID: UUID(), generation: 1))
        f.coordinator.dismissError()
        #expect(f.coordinator.presentationError == nil)
    }

    @Test("blocked origin falls back to ready foreground host")
    func blockedOriginFallsBack() async throws {
        let f = try PresentationFixture(), origin = f.readyHost(), fallback = f.readyHost(), calls = PresentationCalls()
        origin.readiness.report(.libraryRoot, identity: f.identity, blockers: [.activeImport])
        f.register(origin, calls: calls, book: f.book)
        f.register(fallback, calls: calls, book: f.book)
        #expect(f.coordinator.receive(f.source, sceneID: origin.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        #expect(calls.importCount == 1)
    }

    @Test("ready book waits for full readiness instead of selecting idle prompt scene")
    func readyBookRequiresFullReadiness() async throws {
        let f = try PresentationFixture(), importHost = f.readyHost(), promptHost = f.readyHost(), calls = PresentationCalls()
        f.register(importHost, calls: calls, book: f.book, openResult: .unavailable)
        f.register(promptHost, calls: calls, book: f.book)
        #expect(f.coordinator.receive(f.source, sceneID: importHost.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        promptHost.readiness.report(.libraryTab, identity: f.identity, blockers: [.idleFirstBookPrompt])
        f.coordinator.setSceneForeground(id: importHost.id, isForeground: false)
        f.coordinator.requestDrain()
        await settlePresentation()
        #expect(calls.openCount == 1)
        #expect(f.coordinator.hasPendingFile(for: f.identity))
        f.coordinator.setSceneForeground(id: importHost.id, isForeground: true)
        await settlePresentation { calls.openCount == 2 }
        #expect(calls.importCount == 1)
    }

    @Test("inactive host registration waits until the scene becomes active")
    func inactiveRegistrationWaits() async throws {
        let f = try PresentationFixture(), host = f.readyHost(), calls = PresentationCalls()
        let book = f.book
        f.coordinator.registerScene(id: host.id, identity: f.identity, readiness: host.readiness,
            currentIdentity: { f.identity }, prepareForClaim: { true },
            importOwned: { url in calls.imported(); return .init(url: url, book: book, error: nil) },
            refresh: { calls.refreshed() }, open: { _ in calls.opened(); return .presented })
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation()
        #expect(calls.importCount == 0)
        #expect(calls.openCount == 0)
        f.coordinator.setSceneForeground(id: host.id, isForeground: true)
        await settlePresentation { calls.openCount == 1 }
    }

    @Test("unavailable open exhausts three attempts while focused existing counts as success")
    func openAttemptsAndFocusedSuccess() async throws {
        let f = try PresentationFixture(), host = f.readyHost(), calls = PresentationCalls()
        f.register(host, calls: calls, book: f.book, openResult: .unavailable)
        #expect(f.coordinator.receive(f.source, sceneID: host.id, identity: f.identity) == .accepted)
        await settlePresentation { calls.openCount == 1 }
        for expected in 2...3 {
            f.coordinator.requestDrain()
            await settlePresentation { calls.openCount == expected }
        }
        #expect(f.coordinator.presentationError?.message == "Book added. Open it from your Library.")
        f.coordinator.dismissError()

        let other = try PresentationFixture(), secondHost = other.readyHost(), secondCalls = PresentationCalls()
        other.register(secondHost, calls: secondCalls, book: other.book, openResult: .focusedExisting)
        #expect(other.coordinator.receive(other.source, sceneID: secondHost.id, identity: other.identity) == .accepted)
        await settlePresentation { secondCalls.openCount == 1 }
        #expect(secondCalls.importCount == 1)
        #expect(!other.coordinator.hasPendingFile(for: other.identity))
        #expect(other.coordinator.presentationError == nil)
    }
}

@MainActor
private final class PresentationFixture {
    let identity: LibraryAccountIdentity
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let clock = PresentationClock()
    let coordinator: IncomingBookFileCoordinator
    var book: Book { Book(userId: identity.userID, title: "Incoming", formatType: .epub, fileURL: "Books/incoming.epub") }
    init(identity: LibraryAccountIdentity = LibraryAccountIdentity(userID: UUID(), generation: 1), readyLifetime: Duration = .seconds(60)) throws {
        self.identity = identity
        try Data("fixture".utf8).write(to: source)
        var limits = IncomingBookFileCoordinator.Limits()
        limits.readyLifetime = readyLifetime
        coordinator = IncomingBookFileCoordinator(inboxRoot: root, clock: clock, stager: ImmediatePresentationStager(), limits: limits)
    }
    deinit { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
    struct Host { let id: UUID; let readiness: IncomingBookPresentationReadiness }
    func readyHost() -> Host {
        let id = UUID(), state = IncomingBookPresentationReadiness(sceneID: id, identity: identity)
        reportAllEmpty(state)
        return Host(id: id, readiness: state)
    }
    func register(_ host: Host, calls: PresentationCalls, book: Book, importGate: AsyncGate? = nil,
                  openResult: IncomingBookOpenResult = .presented,
                  importAttemptID: @escaping @MainActor () -> UUID? = { nil },
                  didImportSuccessfully: @escaping @MainActor (Book, LibraryAccountIdentity, UUID?) -> Void = { _, _, _ in }) {
        coordinator.registerScene(id: host.id, identity: identity, readiness: host.readiness,
            currentIdentity: { self.identity }, prepareForClaim: { true },
            importOwned: { url in
                calls.imported()
                await importGate?.wait()
                return .init(url: url, book: book, error: nil)
            }, refresh: { calls.refreshed() }, open: { _ in calls.opened(); return openResult },
            importAttemptID: importAttemptID, didImportSuccessfully: didImportSuccessfully)
        coordinator.setSceneForeground(id: host.id, isForeground: true)
    }
    private func reportAllEmpty(_ state: IncomingBookPresentationReadiness) {
        for source in IncomingBookPresentationReadiness.Source.allCases { state.report(source, identity: identity, blockers: []) }
    }
}

private final class PresentationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var imports = 0, opens = 0, refreshes = 0
    private var importWaiters: [CheckedContinuation<Void, Never>] = []
    var importCount: Int { lock.lock(); defer { lock.unlock() }; return imports }
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return opens }
    var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return refreshes }
    func imported() { lock.lock(); imports += 1; let waiting = importWaiters; importWaiters.removeAll(); lock.unlock(); waiting.forEach { $0.resume() } }
    func opened() { lock.lock(); opens += 1; lock.unlock() }
    func refreshed() { lock.lock(); refreshes += 1; lock.unlock() }
    func waitForImport() async {
        if importCount > 0 { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if imports > 0 { lock.unlock(); continuation.resume() }
            else { importWaiters.append(continuation); lock.unlock() }
        }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func open() {
        lock.lock(); isOpen = true; let waiting = waiters; waiters.removeAll(); lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

private nonisolated final class PresentationClock: IncomingBookClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private var waiters: [(UUID, Duration, CheckedContinuation<Void, any Error>)] = []
    func now() -> Duration { lock.lock(); defer { lock.unlock() }; return time }
    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                let deadline = time + duration
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else if deadline <= time { lock.unlock(); continuation.resume() }
                else { waiters.append((id, deadline, continuation)); lock.unlock() }
            }
        } onCancel: { self.cancel(id) }
    }
    func advance(by duration: Duration) {
        lock.lock(); time += duration
        let due = waiters.filter { $0.1 <= time }; waiters.removeAll { $0.1 <= time }; lock.unlock()
        due.forEach { $0.2.resume() }
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { lock.unlock(); return }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.2.resume(throwing: CancellationError())
    }
}

private nonisolated struct ImmediatePresentationStager: IncomingBookStager {
    func stage(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64,
                cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64 {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return Int64(data.count)
    }
}

@MainActor
private func settlePresentation(until predicate: () -> Bool = { true }) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate(), "Timed out waiting for coordinator presentation state")
}

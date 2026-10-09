import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Incoming book file coordination")
struct IncomingBookFileCoordinatorTests {
    @Test("unsupported format is rejected and error ownership is elected from foreground roots")
    func unsupportedAndRootElection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = IncomingBookFileCoordinator(inboxRoot: root)
        let first = UUID()
        let second = UUID()
        coordinator.registerRootScene(id: first, isForeground: true)
        coordinator.registerRootScene(id: second, isForeground: false)

        #expect(coordinator.receive(URL(fileURLWithPath: "/tmp/book.mobi"), sceneID: first, identity: nil) == .unsupported)
        #expect(coordinator.presentationError != nil)
        #expect(coordinator.selectedRootErrorSceneID == first)
        #expect(!coordinator.hasPendingFile)

        coordinator.setRootSceneForeground(id: second, isForeground: true)
        #expect(coordinator.selectedRootErrorSceneID == second)
        coordinator.dismissError()
        #expect(coordinator.presentationError == nil)
    }

    @Test("startup clears stale inbox contents")
    func startupClearsOldContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("old-event")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = IncomingBookFileCoordinator(inboxRoot: root)

        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == [])
    }

    @Test("same-account duplicate joins ingress; a new account never joins the revoked event")
    func identityScopedDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try Data("book".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let coordinator = IncomingBookFileCoordinator(inboxRoot: root, stager: CopyingIncomingBookStager())
        let a = LibraryAccountIdentity(userID: UUID(), generation: 1)
        let b = LibraryAccountIdentity(userID: UUID(), generation: 2)

        #expect(coordinator.receive(source, sceneID: nil, identity: a) == .accepted)
        #expect(coordinator.receive(source, sceneID: UUID(), identity: a) == .duplicate)
        coordinator.accountDidChange(from: a, to: nil)
        #expect(coordinator.receive(source, sceneID: nil, identity: b) == .accepted)
        #expect(!coordinator.hasPendingFile(for: a))
    }

    @Test("ready signed-in host imports once and opens the retained book once")
    func importsAndPresentsOnce() async throws {
        let fixture = try CoordinatorFixture()
        let identity = fixture.identity
        let readiness = fixture.readyHost(identity: identity)
        let book = Book(userId: identity.userID, title: "Incoming", formatType: .epub, fileURL: "Books/incoming.epub")
        let calls = CoordinatorCallRecorder()
        fixture.coordinator.registerScene(id: readiness.id, identity: identity, readiness: readiness.readiness,
            currentIdentity: { identity }, prepareForClaim: { true },
            importOwned: { url in calls.imported(url); return ImportCoordinator.ImportOutcome(url: url, book: book, error: nil) },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(readiness.id)
        #expect(fixture.coordinator.receive(fixture.source, sceneID: readiness.id, identity: identity) == .accepted)
        try await settleCoordinator { calls.importCount == 1 && calls.openCount == 1 && !fixture.coordinator.hasPendingFile }
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 1)
        #expect(!fixture.coordinator.hasPendingFile)
    }

    @Test("import failure never opens a book and global error gates another host")
    func importFailureAndGlobalGate() async throws {
        let fixture = try CoordinatorFixture()
        let identity = fixture.identity
        let host = fixture.readyHost(identity: identity)
        let calls = CoordinatorCallRecorder()
        fixture.coordinator.registerScene(id: host.id, identity: identity, readiness: host.readiness,
            currentIdentity: { identity }, prepareForClaim: { true },
            importOwned: { url in calls.imported(url); return ImportCoordinator.ImportOutcome(url: url, book: nil, error: "failed") },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(host.id)
        #expect(fixture.coordinator.receive(fixture.source, sceneID: host.id, identity: identity) == .accepted)
        try await settleCoordinator { calls.importCount == 1 && fixture.coordinator.presentationError != nil }
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 0)
        #expect(fixture.coordinator.presentationError != nil)
        fixture.coordinator.dismissError()
    }

    @Test("unready host does not claim or import; readiness report resumes the queue")
    func readinessBlocksClaimAndResumes() async throws {
        let fixture = try CoordinatorFixture()
        let identity = fixture.identity
        let host = fixture.readyHost(identity: identity)
        host.readiness.report(.libraryTab, identity: identity, blockers: [.idleFirstBookPrompt])
        let calls = CoordinatorCallRecorder()
        let prepareCalls = CoordinatorPrepareCallRecorder()
        let book = Book(userId: identity.userID, title: "Ready later", formatType: .epub, fileURL: "Books/later.epub")
        let readiness = host.readiness
        fixture.coordinator.registerScene(id: host.id, identity: identity, readiness: host.readiness,
            currentIdentity: { identity }, prepareForClaim: { prepareCalls.record(); return false },
            importOwned: { url in
                let hostWasReady = await MainActor.run { readiness.isReady(for: identity) }
                calls.imported(url, hostWasReady: hostWasReady)
                return ImportCoordinator.ImportOutcome(url: url, book: book, error: nil)
            },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(host.id)
        #expect(fixture.coordinator.receive(fixture.source, sceneID: host.id, identity: identity) == .accepted)
        try await settleCoordinator { prepareCalls.count == 1 }
        #expect(calls.importCount == 0)
        #expect(fixture.coordinator.hasPendingFile)
        #expect(!host.readiness.isReady(for: identity))
        host.readiness.report(.libraryTab, identity: identity, blockers: [])
        fixture.coordinator.requestDrain()
        try await settleCoordinator { calls.importCount == 1 && calls.openCount == 1 && !fixture.coordinator.hasPendingFile }
        #expect(!calls.importedWhileBlocked)
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 1)
    }

    @Test("signed-out receive binds to first account and survives chosen host unregister")
    func firstSignInAndHostHandoff() async throws {
        let fixture = try CoordinatorFixture()
        let identity = fixture.identity
        let first = fixture.readyHost(identity: identity)
        let second = fixture.readyHost(identity: identity)
        let calls = CoordinatorCallRecorder()
        let book = Book(userId: identity.userID, title: "Handoff", formatType: .epub, fileURL: "Books/handoff.epub")
        let importClosure: @Sendable (URL) async -> ImportCoordinator.ImportOutcome = { url in
            calls.imported(url)
            return ImportCoordinator.ImportOutcome(url: url, book: book, error: nil)
        }
        fixture.coordinator.registerScene(id: first.id, identity: identity, readiness: first.readiness,
            currentIdentity: { identity }, prepareForClaim: { true }, importOwned: importClosure,
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(first.id)
        fixture.coordinator.registerScene(id: second.id, identity: identity, readiness: second.readiness,
            currentIdentity: { identity }, prepareForClaim: { true }, importOwned: importClosure,
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(second.id)
        #expect(fixture.coordinator.receive(fixture.source, sceneID: nil, identity: nil) == .accepted)
        fixture.coordinator.accountDidChange(from: nil, to: identity)
        fixture.coordinator.unregisterScene(id: first.id)
        fixture.coordinator.requestDrain()
        try await settleCoordinator { calls.importCount == 1 && calls.openCount == 1 && !fixture.coordinator.hasPendingFile }
        #expect(calls.importCount == 1)
        #expect(calls.openCount == 1)
    }

    @Test("account switch revokes pending file before another account can import it")
    func accountSwitchRevokesQueuedFile() async throws {
        let fixture = try CoordinatorFixture()
        let a = fixture.identity
        let b = LibraryAccountIdentity(userID: UUID(), generation: 2)
        let hostA = fixture.readyHost(identity: a)
        let calls = CoordinatorCallRecorder()
        fixture.coordinator.registerScene(id: hostA.id, identity: a, readiness: hostA.readiness,
            currentIdentity: { a }, prepareForClaim: { true },
            importOwned: { url in calls.imported(url); return ImportCoordinator.ImportOutcome(url: url, book: nil, error: "unexpected") },
            refresh: {}, open: { _ in calls.opened(); return .presented })
        fixture.activateScene(hostA.id)
        #expect(fixture.coordinator.receive(fixture.source, sceneID: hostA.id, identity: a) == .accepted)
        fixture.coordinator.accountDidChange(from: a, to: b)
        let revisionAfterRevocation = fixture.coordinator.revision
        try await settleCoordinator { fixture.coordinator.revision > revisionAfterRevocation }
        #expect(calls.importCount == 0)
        #expect(!fixture.coordinator.hasPendingFile(for: a))
        #expect(!fixture.coordinator.hasPendingFile(for: b))
    }
}

@MainActor
private final class CoordinatorFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
    let identity = LibraryAccountIdentity(userID: UUID(), generation: 1)
    let coordinator: IncomingBookFileCoordinator
    init() throws {
        try Data("fixture".utf8).write(to: source)
        coordinator = IncomingBookFileCoordinator(inboxRoot: root, stager: CopyingIncomingBookStager())
    }
    deinit { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
    struct Host {
        let id: UUID
        let readiness: IncomingBookPresentationReadiness
    }
    func readyHost(identity: LibraryAccountIdentity) -> Host {
        let id = UUID()
        let readiness = IncomingBookPresentationReadiness(sceneID: id, identity: identity)
        for source in IncomingBookPresentationReadiness.Source.allCases {
            readiness.report(source, identity: identity, blockers: [])
        }
        return Host(id: id, readiness: readiness)
    }

    func activateScene(_ id: UUID) {
        coordinator.setSceneForeground(id: id, isForeground: true)
    }
}

@MainActor
private final class CoordinatorPrepareCallRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class CoordinatorCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var imports = 0
    private var opens = 0
    private var blockedImports = 0
    var importCount: Int { lock.lock(); defer { lock.unlock() }; return imports }
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return opens }
    var importedWhileBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blockedImports > 0 }
    func imported(_ url: URL, hostWasReady: Bool? = nil) {
        lock.lock()
        imports += 1
        if hostWasReady == false { blockedImports += 1 }
        lock.unlock()
    }
    func opened() { lock.lock(); opens += 1; lock.unlock() }
}

@MainActor
private func settleCoordinator(until predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    throw CoordinatorWaitTimeout()
}

private struct CoordinatorWaitTimeout: Error {}

private nonisolated struct CopyingIncomingBookStager: IncomingBookStager {
    func stage(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64, cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64 {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw CancellationError() }
        let data = try Data(contentsOf: source)
        guard Int64(data.count) <= maximumBytes else { throw IncomingBookStagingError.fileTooLarge }
        if Int64(data.count) > initiallyReservedBytes,
           !reserveGrowth(Int64(data.count) - initiallyReservedBytes) { throw IncomingBookStagingError.aggregateLimit }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return Int64(data.count)
    }
}

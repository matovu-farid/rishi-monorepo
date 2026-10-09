import Foundation
import Testing
@testable import rishi

@MainActor
struct IncomingBookFileCoordinatorResourceTests {
    @Test("out-of-order staging still imports in arrival order")
    func stagingCompletesOutOfOrderButImportsFIFO() async throws {
        let f = try ResourceFixture(limits: .init(entries: 4, perFileBytes: 100, aggregateBytes: 100))
        let a = try f.source("a.epub", bytes: 4), b = try f.source("b.epub", bytes: 4)
        let identity = f.identity()
        let imported = ResourceImportRecorder()
        let book = Book(userId: identity.userID, title: "FIFO", formatType: .epub, fileURL: "Books/fifo.epub")
        f.register(identity: identity, open: { _ in .presented }) { url in imported.record(url.lastPathComponent); return .init(url: url, book: book, error: nil) }
        #expect(f.coordinator.receive(a, sceneID: nil, identity: identity) == .accepted)
        #expect(f.coordinator.receive(b, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(2)
        await f.stager.release(source: b)
        await f.stager.waitForChunks(1)
        await f.stager.release(source: a)
        await f.stager.waitForChunks(2)
        try await settleResources { imported.values.count == 2 && !f.coordinator.hasPendingFile }
        #expect(imported.values == ["a.epub", "b.epub"])
    }

    @Test("revoked staging completion cannot import and another account can reuse the URL")
    func revokedLateCompletionAndSameURL() async throws {
        let f = try ResourceFixture(limits: .init(entries: 3, perFileBytes: 100, aggregateBytes: 100))
        let url = try f.source("shared.epub", bytes: 6), a = f.identity(), b = f.identity()
        let imports = ResourceImportRecorder()
        f.register(identity: a) { _ in imports.record("import"); return .init(url: url, book: nil, error: "unexpected") }
        #expect(f.coordinator.receive(url, sceneID: nil, identity: a) == .accepted)
        await f.stager.waitForBegins(1)
        f.coordinator.accountDidChange(from: a, to: b)
        #expect(await f.stager.wasCancelled(0))
        #expect(f.coordinator.receive(url, sceneID: nil, identity: b) == .accepted)
        await f.stager.waitForBegins(2)
        let revisionBeforeOldCompletion = f.coordinator.revision
        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources { f.coordinator.revision > revisionBeforeOldCompletion }
        #expect(imports.values.isEmpty)
        #expect(f.coordinator.receive(url, sceneID: nil, identity: b) == .duplicate)
        let revisionBeforeNewCompletion = f.coordinator.revision
        await f.stager.release(1, failure: true)
        await f.stager.waitForChunks(2)
        try await settleResources { f.coordinator.revision > revisionBeforeNewCompletion && !f.coordinator.hasPendingFile }
    }

    @Test("signed-out staging binds to its first resolved identity")
    func signedOutEntryBindsOnce() async throws {
        let f = try ResourceFixture(limits: .init(entries: 3, perFileBytes: 100, aggregateBytes: 100))
        let url = try f.source("unclaimed.pdf", bytes: 5), a = f.identity(), b = f.identity()
        #expect(f.coordinator.receive(url, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(1)
        f.coordinator.accountDidChange(from: nil, to: a)
        #expect(f.coordinator.hasPendingFile(for: a))
        f.coordinator.accountDidChange(from: a, to: b)
        #expect(!f.coordinator.hasPendingFile(for: a))
        #expect(!f.coordinator.hasPendingFile(for: b))
        let revisionBeforeCompletion = f.coordinator.revision
        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources { f.coordinator.revision > revisionBeforeCompletion && !f.coordinator.hasPendingFile }
        #expect(!f.coordinator.hasPendingFile(for: b))
    }

    @Test("aggregate byte and entry reservations reject before staging and free after failure")
    func reservationsRejectAndRelease() async throws {
        let f = try ResourceFixture(limits: .init(entries: 2, perFileBytes: 20, aggregateBytes: 8))
        let one = try f.source("one.epub", bytes: 6), two = try f.source("two.epub", bytes: 3), identity = f.identity()
        #expect(f.coordinator.receive(one, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(1)
        #expect(f.coordinator.receive(two, sceneID: nil, identity: identity) == .failed)
        #expect(await f.stager.beginCount == 1)
        await f.stager.release(0, failure: true)
        try await settleResources { !f.coordinator.hasPendingFile }
        f.coordinator.dismissError()
        #expect(f.coordinator.receive(two, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(2)
        let three = try f.source("three.epub", bytes: 2), four = try f.source("four.epub", bytes: 1)
        #expect(f.coordinator.receive(three, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(3)
        #expect(f.coordinator.receive(four, sceneID: nil, identity: identity) == .failed)
        #expect(await f.stager.beginCount == 3)
        let revisionBeforeCleanup = f.coordinator.revision
        await f.stager.release(source: two, failure: true)
        await f.stager.release(source: three, failure: true)
        await f.stager.waitForChunks(3)
        try await settleResources {
            f.coordinator.revision >= revisionBeforeCleanup + 2
                && !f.coordinator.hasPendingFile
                && f.coordinator.presentationError != nil
        }
    }

    @Test("per-file overflow and aggregate growth failure clean partial copies and release reservations")
    func copyOverflowCleansAndReleases() async throws {
        let f = try ResourceFixture(limits: .init(entries: 3, perFileBytes: 8, aggregateBytes: 6))
        let url = try f.source("grow.epub", bytes: 3), identity = f.identity()
        #expect(f.coordinator.receive(url, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(1)
        try Data(repeating: 1, count: 12).write(to: url)
        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources { !f.coordinator.hasPendingFile }
        #expect(f.coordinator.presentationError != nil)
        #expect(!(await f.stager.partialDirectory(at: 0).map { FileManager.default.fileExists(atPath: $0.path) } ?? true))
        f.coordinator.dismissError()
        let afterFailures = try f.source("released.epub", bytes: 2)
        #expect(f.coordinator.receive(afterFailures, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(2)
        #expect(await f.stager.beginCount == 2)
        await f.stager.release(source: afterFailures, failure: true)
        await f.stager.waitForChunks(2)
        try await settleResources { !f.coordinator.hasPendingFile }
        #expect(f.coordinator.presentationError != nil)
        f.coordinator.dismissError()

        let second = try f.source("aggregate.epub", bytes: 3)
        #expect(f.coordinator.receive(second, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(3)
        try Data(repeating: 2, count: 7).write(to: second)
        await f.stager.release(source: second)
        await f.stager.waitForChunks(3)
        try await settleResources { !f.coordinator.hasPendingFile }
        #expect(f.coordinator.presentationError != nil)
        #expect(!(await f.stager.partialDirectory(at: 2).map { FileManager.default.fileExists(atPath: $0.path) } ?? true))
        f.coordinator.dismissError()
        let reservationCheck = try f.source("reservation-check.epub", bytes: 4)
        #expect(f.coordinator.receive(reservationCheck, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(4)
        await f.stager.release(source: reservationCheck, failure: true)
        await f.stager.waitForChunks(4)
        try await settleResources { !f.coordinator.hasPendingFile }
    }

    @Test("signed-out expiry runs on the fake clock and foreground sweep catches a missed timer")
    func signedOutExpiryAndForegroundSweep() async throws {
        let f = try ResourceFixture(limits: .init(entries: 3, perFileBytes: 20, aggregateBytes: 40, signedOutExpiry: .seconds(1)))
        let first = try f.source("timer.epub", bytes: 3)
        #expect(f.coordinator.receive(first, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(1)
        await f.stager.release(0); await f.stager.waitForChunks(1)
        await f.clock.waitForSleeps(1)
        await f.clock.advance(by: .seconds(1))
        try await settleResources { !f.coordinator.hasPendingFile }
        #expect(!f.coordinator.hasPendingFile)

        let priorTimerRegistrations = f.clock.sleepRegistrationCount
        let second = try f.source("sweep.epub", bytes: 3)
        #expect(f.coordinator.receive(second, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(2); await f.stager.release(1); await f.stager.waitForChunks(2)
        await f.clock.waitForSleeps(priorTimerRegistrations + 1)
        await f.clock.advance(by: .seconds(1), deliver: false)
        #expect(f.coordinator.hasPendingFile)
        f.coordinator.foregroundSceneDidActivate()
        #expect(!f.coordinator.hasPendingFile)
    }

    @Test("signed-out expiry cancels staging but retains reservations until provider cleanup")
    func expiryDuringStagingRetainsReservationAndCleansLateOutput() async throws {
        let scopes = ResourceSecurityScopeRecorder()
        let f = try ResourceFixture(
            limits: .init(entries: 2, perFileBytes: 10, aggregateBytes: 5, signedOutExpiry: .seconds(1)),
            securityScopes: scopes
        )
        let first = try f.source("slow.epub", bytes: 4)
        #expect(f.coordinator.receive(first, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(1)
        await f.clock.waitForSleeps(1)
        await f.clock.advance(by: .seconds(1))
        await f.stager.waitForCancellation(0)
        #expect(await f.stager.wasCancelled(0))
        #expect(!f.coordinator.hasPendingFile)
        #expect(await f.stager.partialDirectories.count == 1)
        let oldPartialDirectory = await f.stager.partialDirectory(at: 0)

        let next = try f.source("next.epub", bytes: 2)
        #expect(f.coordinator.receive(next, sceneID: nil, identity: nil) == .failed)
        #expect(await f.stager.beginCount == 1)
        #expect(scopes.startCount == 2)
        #expect(scopes.stopCount == 1)

        let countFiller = try f.source("filler.epub", bytes: 1)
        #expect(f.coordinator.receive(countFiller, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(2)
        let countBlocked = try f.source("count-blocked.epub", bytes: 1)
        #expect(f.coordinator.receive(countBlocked, sceneID: nil, identity: nil) == .failed)

        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources {
            scopes.stopCount == 2
                && !(oldPartialDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        }
        f.coordinator.dismissError()
        await f.stager.release(1, failure: true)
        await f.stager.waitForChunks(2)
        try await settleResources { scopes.stopCount == 3 }
        f.coordinator.dismissError()
        #expect(f.coordinator.receive(next, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(3)
        await f.stager.release(2, failure: true)
        await f.stager.waitForChunks(3)
        try await settleResources { scopes.stopCount == 4 }
        #expect(scopes.startCount == 4)
        #expect(scopes.stopCount == 4)
    }

    @Test("expired same-URL staging can be reopened without old cleanup clearing the new dedupe")
    func reopenSameURLDuringExpiredStaging() async throws {
        let f = try ResourceFixture(limits: .init(entries: 3, perFileBytes: 10, aggregateBytes: 12, signedOutExpiry: .seconds(1)))
        let url = try f.source("reopen.epub", bytes: 4)
        #expect(f.coordinator.receive(url, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(1)
        await f.clock.waitForSleeps(1)
        await f.clock.advance(by: .seconds(1))
        await f.stager.waitForCancellation(0)
        #expect(await f.stager.wasCancelled(0))

        #expect(f.coordinator.receive(url, sceneID: nil, identity: nil) == .accepted)
        await f.stager.waitForBegins(2)
        let oldPartialDirectory = await f.stager.partialDirectory(at: 0)
        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources {
            !(oldPartialDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        }
        #expect(f.coordinator.receive(url, sceneID: nil, identity: nil) == .duplicate)

        let identity = f.identity()
        f.coordinator.accountDidChange(from: nil, to: identity)
        let imported = ResourceImportRecorder(), opened = ResourceImportRecorder()
        let book = Book(userId: identity.userID, title: "Reopened", formatType: .epub, fileURL: "Books/reopened.epub")
        f.register(identity: identity, open: { _ in opened.record("opened"); return .presented }) { stagedURL in
            imported.record(stagedURL.pathExtension)
            return .init(url: stagedURL, book: book, error: nil)
        }
        await f.stager.release(1)
        await f.stager.waitForChunks(2)
        try await settleResources { imported.values == ["epub"] && opened.values == ["opened"] }
        #expect(!f.coordinator.hasPendingFile)
    }

    @Test("long source filenames retain a bounded supported extension through import")
    func longFilenamePreservesFormatExtension() async throws {
        let f = try ResourceFixture(limits: .init(entries: 2, perFileBytes: 1_000, aggregateBytes: 2_000))
        let identity = f.identity()
        let source = try f.source(String(repeating: "Readable Title ", count: 15) + ".EPUB", bytes: 4)
        let importedNames = ResourceImportRecorder()
        let book = Book(userId: identity.userID, title: "Long title", formatType: .epub, fileURL: "Books/long.epub")
        f.register(identity: identity, open: { _ in .presented }) { url in
            importedNames.record(url.lastPathComponent)
            return .init(url: url, book: book, error: nil)
        }
        #expect(f.coordinator.receive(source, sceneID: nil, identity: identity) == .accepted)
        await f.stager.waitForBegins(1)
        await f.stager.release(0)
        await f.stager.waitForChunks(1)
        try await settleResources { !importedNames.values.isEmpty }
        let stagedName = try #require(importedNames.values.first)
        #expect(URL(fileURLWithPath: stagedName).pathExtension == "epub")
        #expect(stagedName.unicodeScalars.count <= 180)
        #expect(URL(fileURLWithPath: stagedName).deletingPathExtension().lastPathComponent.hasPrefix("Readable Title"))
    }
}

@MainActor
private final class ResourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stager = GatedIncomingBookStager()
    let clock = GatedIncomingBookClock()
    let coordinator: IncomingBookFileCoordinator
    init(limits: IncomingBookFileCoordinator.Limits, securityScopes: ResourceSecurityScopeRecorder? = nil) throws {
        coordinator = IncomingBookFileCoordinator(
            inboxRoot: root,
            clock: clock,
            stager: stager,
            limits: limits,
            startAccessing: { url in
                guard let securityScopes else { return url.startAccessingSecurityScopedResource() }
                securityScopes.didStart()
                return true
            },
            stopAccessing: { url in
                guard let securityScopes else { url.stopAccessingSecurityScopedResource(); return }
                securityScopes.didStop()
            }
        )
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func source(_ name: String, bytes: Int) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }
    func identity() -> LibraryAccountIdentity { .init(userID: UUID(), generation: 1) }
    func register(identity: LibraryAccountIdentity, open: @escaping @MainActor (Book) -> IncomingBookOpenResult = { _ in .unavailable }, importing: @escaping @Sendable (URL) -> ImportCoordinator.ImportOutcome) {
        let id = UUID(), readiness = IncomingBookPresentationReadiness(sceneID: id, identity: identity)
        for source in IncomingBookPresentationReadiness.Source.allCases { readiness.report(source, identity: identity, blockers: []) }
        coordinator.registerScene(id: id, identity: identity, readiness: readiness, currentIdentity: { identity }, prepareForClaim: { true }, importOwned: { url in importing(url) }, refresh: {}, open: open)
        activateScene(id)
    }
    private func activateScene(_ id: UUID) {
        coordinator.setSceneForeground(id: id, isForeground: true)
    }
}

@MainActor
private func settleResources(_ predicate: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    throw ResourceWaitTimeout()
}

private struct ResourceWaitTimeout: Error {}

private final class ResourceImportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class ResourceSecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func didStart() { lock.lock(); starts += 1; lock.unlock() }
    func didStop() { lock.lock(); stops += 1; lock.unlock() }
}

private nonisolated struct GatedIncomingBookStager: IncomingBookStager {
    private let gate = StageGate()
    var beginCount: Int { get async { await gate.beginCount } }
    var partialDirectories: [URL] { get async { await gate.partialDirectories } }
    func partialDirectory(at index: Int) async -> URL? { await gate.partialDirectory(at: index) }
    func waitForBegins(_ count: Int) async { await gate.waitForBegins(count) }
    func waitForChunks(_ count: Int) async { await gate.waitForChunks(count) }
    func waitForCancellation(_ index: Int) async { await gate.waitForCancellation(index) }
    func wasCancelled(_ index: Int) async -> Bool { await gate.wasCancelled(index) }
    func release(_ index: Int, failure: Bool = false) async { await gate.release(index, failure: failure) }
    func release(source: URL, failure: Bool = false) async { await gate.release(source: source, failure: failure) }
    func stage(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64, cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64 {
        try await gate.perform(source: source, destination: destination, maximumBytes: maximumBytes, initiallyReservedBytes: initiallyReservedBytes, cancellation: cancellation, reserveGrowth: reserveGrowth)
    }
}

private actor StageGate {
    private struct Job { let source: URL; let destination: URL; let maximum: Int64; let initial: Int64; let growth: @Sendable (Int64) -> Bool; let cancellation: IncomingBookCancellationFlag; let continuation: CheckedContinuation<Int64, Error> }
    private var jobs: [Job] = []
    private var begins = 0, chunks = 0
    private var partialPaths: [URL] = []
    var partialDirectories: [URL] { partialPaths.filter { FileManager.default.fileExists(atPath: $0.path) } }
    func partialDirectory(at index: Int) -> URL? { partialPaths.indices.contains(index) ? partialPaths[index] : nil }
    var beginCount: Int { begins }
    func wasCancelled(_ index: Int) -> Bool { jobs.indices.contains(index) && jobs[index].cancellation.isCancelled }
    func waitForBegins(_ count: Int) async { await waitUntil { begins >= count } }
    func waitForChunks(_ count: Int) async { await waitUntil { chunks >= count } }
    func waitForCancellation(_ index: Int) async {
        await waitUntil { jobs.indices.contains(index) && jobs[index].cancellation.isCancelled }
    }
    func perform(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64, cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64 {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: destination); partialPaths.append(destination.deletingLastPathComponent())
        begins += 1
        return try await withCheckedThrowingContinuation { jobs.append(Job(source: source, destination: destination, maximum: maximumBytes, initial: initiallyReservedBytes, growth: reserveGrowth, cancellation: cancellation, continuation: $0)) }
    }
    func release(_ index: Int, failure: Bool) {
        guard jobs.indices.contains(index) else { return }
        release(jobs[index], failure: failure)
    }
    func release(source: URL, failure: Bool) {
        guard let job = jobs.first(where: { $0.source == source }) else { return }
        release(job, failure: failure)
    }
    private func release(_ job: Job, failure: Bool) {
        chunks += 1
        if failure { job.continuation.resume(throwing: IncomingBookStagingError.unreadable); return }
        do {
            let data = try Data(contentsOf: job.source), size = Int64(data.count)
            guard size <= job.maximum else { throw IncomingBookStagingError.fileTooLarge }
            if size > job.initial, !job.growth(size - job.initial) { throw IncomingBookStagingError.aggregateLimit }
            try data.write(to: job.destination)
            job.continuation.resume(returning: size)
        } catch { job.continuation.resume(throwing: error) }
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Stager gate timed out waiting for its deterministic event")
    }
}

private nonisolated struct GatedIncomingBookClock: IncomingBookClock {
    private let state = ClockState()
    func now() -> Duration { state.now }
    func sleep(for duration: Duration) async throws { await state.sleep(for: duration) }
    func waitForSleeps(_ count: Int) async { await state.waitForSleeps(count) }
    var sleepRegistrationCount: Int { state.sleepRegistrationCount }
    func advance(by duration: Duration, deliver: Bool = true) async { await state.advance(by: duration, deliver: deliver) }
}

private nonisolated final class ClockState: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Duration = .zero
    private var sleeps: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var sleepRegistrations = 0
    var now: Duration { lock.lock(); defer { lock.unlock() }; return instant }
    var sleepRegistrationCount: Int { lock.lock(); defer { lock.unlock() }; return sleepRegistrations }
    func waitForSleeps(_ count: Int) async {
        for _ in 0..<10_000 {
            lock.lock(); let ready = sleepRegistrations >= count; lock.unlock()
            if ready { return }
            await Task.yield()
        }
        Issue.record("Fake clock timed out waiting for timer registration \(count)")
    }
    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.lock(); sleepRegistrations += 1; sleeps.append((instant + duration, continuation)); lock.unlock()
        }
    }
    func advance(by duration: Duration, deliver: Bool) {
        lock.lock(); instant += duration
        let ready: [CheckedContinuation<Void, Never>]
        if deliver { let due = sleeps.filter { $0.0 <= instant }; sleeps.removeAll { $0.0 <= instant }; ready = due.map(\.1) } else { ready = [] }
        lock.unlock(); ready.forEach { $0.resume() }
    }
}

import Foundation
import Observation

enum ReceiveDisposition: Equatable, Sendable { case accepted, duplicate, unsupported, failed }
enum IncomingBookOpenResult: Equatable, Sendable { case presented, focusedExisting, unavailable }

struct PresentationError: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String
    init(id: UUID = UUID(), message: String) { self.id = id; self.message = message }
}

nonisolated protocol IncomingBookClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

nonisolated struct SystemIncomingBookClock: IncomingBookClock {
    private static let origin = ContinuousClock().now
    private let clock = ContinuousClock()
    func now() -> Duration { Self.origin.duration(to: clock.now) }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

nonisolated protocol IncomingBookStager: Sendable {
    func stage(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64, cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64
}

nonisolated final class IncomingBookCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private nonisolated final class IncomingBookByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private var total: Int64 = 0
    private var reservations: [UUID: Int64] = [:]
    init(limit: Int64) { self.limit = limit }
    func reserve(_ amount: Int64, for id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard amount >= 0, total + amount <= limit else { return false }
        total += amount; reservations[id] = (reservations[id] ?? 0) + amount
        return true
    }
    func release(_ id: UUID) { lock.lock(); defer { lock.unlock() }; total -= reservations.removeValue(forKey: id) ?? 0 }
}

nonisolated struct CoordinatedIncomingBookStager: IncomingBookStager {
    func stage(source: URL, destination: URL, maximumBytes: Int64, initiallyReservedBytes: Int64, cancellation: IncomingBookCancellationFlag, reserveGrowth: @escaping @Sendable (Int64) -> Bool) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            let folder = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var backupValues = URLResourceValues(); backupValues.isExcludedFromBackup = true
            var ownedFolder = folder
            try? ownedFolder.setResourceValues(backupValues)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<Int64, Error>!
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
                result = Result {
                    let input = try FileHandle(forReadingFrom: coordinatedURL)
                    defer { try? input.close() }
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    var ownedFile = destination
                    try? ownedFile.setResourceValues(backupValues)
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    var copied: Int64 = 0
                    while true {
                        if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
                        guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                        let next = copied + Int64(chunk.count)
                        guard next <= maximumBytes else { throw IncomingBookStagingError.fileTooLarge }
                        if next > initiallyReservedBytes, !reserveGrowth(next - max(copied, initiallyReservedBytes)) { throw IncomingBookStagingError.aggregateLimit }
                        try output.write(contentsOf: chunk)
                        copied = next
                    }
                    return copied
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw IncomingBookStagingError.unreadable }
            return try result.get()
        }.value
    }
}

nonisolated enum IncomingBookStagingError: Error, Sendable { case fileTooLarge, aggregateLimit, unreadable }

@MainActor
@Observable
final class IncomingBookFileCoordinator {
    struct Limits: Sendable {
        var entries = 8
        var perFileBytes: Int64 = 1_073_741_824
        var aggregateBytes: Int64 = 2_147_483_648
        var signedOutExpiry: Duration = .seconds(1_800)
        var duplicateWindow: Duration = .seconds(3)
        var readyLifetime: Duration = .seconds(60)
        var openAttempts = 3
        var dismissalTimeout: Duration = .seconds(10)
        static let production = Limits()
    }

    static let shared = IncomingBookFileCoordinator()

    private(set) var hasPendingFile = false
    private(set) var presentationError: PresentationError?
    private var presentationErrorIdentity: LibraryAccountIdentity?
    private(set) var revision: UInt64 = 0
    private(set) var selectedRootErrorSceneID: UUID?
    private(set) var resolvedIdentity: LibraryAccountIdentity?

    private struct RootHost { let registrationToken: UUID; var foreground: Bool; var recency: UInt64 }
    private struct Host {
        let registrationToken: UUID
        let identity: LibraryAccountIdentity?
        let readiness: IncomingBookPresentationReadiness
        let currentIdentity: @MainActor () -> LibraryAccountIdentity?
        let importAttemptID: @MainActor () -> UUID?
        let didImportSuccessfully: @MainActor (Book, LibraryAccountIdentity, UUID?) -> Void
        let prepareForClaim: @MainActor () async -> Bool
        let importOwned: @Sendable (URL) async -> ImportCoordinator.ImportOutcome
        let refresh: @MainActor () async -> Void
        let open: @MainActor (Book) -> IncomingBookOpenResult
        var foreground: Bool
        var recency: UInt64
    }
    private enum State { case staging, queued, importing, ready(Book, LibraryAccountIdentity, Duration, Int), finished }
    private struct Entry {
        let id: UUID
        let sequence: UInt64
        let sourceKey: String
        let safeName: String
        let originScene: UUID?
        var identity: LibraryAccountIdentity?
        var state: State
        var stagedURL: URL?
        var reservedBytes: Int64
        var revoked = false
        var scopeStarted = false
        var expiresAt: Duration?

    }

    private let inboxRoot: URL
    private let fileManager: FileManager
    private let clock: any IncomingBookClock
    private let stager: any IncomingBookStager
    private let limits: Limits
    private let startAccessing: (URL) -> Bool
    private let stopAccessing: (URL) -> Void
    private var entries: [UUID: Entry] = [:]
    private var arrival: [UUID] = []
    private var roots: [UUID: RootHost] = [:]
    private var preferredErrorSceneID: UUID?
    private struct PendingNotice: Equatable {
        let identity: LibraryAccountIdentity?
        let message: String
        let preferredSceneID: UUID?
    }
    private var pendingNotices: [PendingNotice] = []
    private var hosts: [UUID: Host] = [:]
    private var inFlightByURL: [String: UUID] = [:]
    private var completed: [String: (identity: LibraryAccountIdentity?, until: Duration)] = [:]
    private let byteBudget: IncomingBookByteBudget
    private var cancellations: [UUID: IncomingBookCancellationFlag] = [:]
    private var prepareWaiters: [UUID: CheckedContinuation<ClaimPreparation, Never>] = [:]
    private var prepareTimeouts: [UUID: Task<Void, Never>] = [:]
    private enum ClaimPreparation { case ready, denied, timedOut }
    private var sequence: UInt64 = 0
    private var recency: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var drainWakeRequested = false
    private var expiryTask: Task<Void, Never>?

    init(inboxRoot: URL? = nil, fileManager: FileManager = .default, clock: any IncomingBookClock = SystemIncomingBookClock(), stager: any IncomingBookStager = CoordinatedIncomingBookStager(), limits: Limits = .production, startAccessing: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }, stopAccessing: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.fileManager = fileManager
        self.clock = clock
        self.stager = stager
        self.limits = limits
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.byteBudget = IncomingBookByteBudget(limit: limits.aggregateBytes)
        let root = inboxRoot ?? ((try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory).appendingPathComponent("IncomingBookFiles", isDirectory: true)
        self.inboxRoot = root
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    func hasPendingFile(for identity: LibraryAccountIdentity) -> Bool {
        entries.values.contains { !$0.revoked && $0.identity == identity && !isFinished($0.state) }
    }

    func isRootSceneForeground(_ id: UUID) -> Bool { roots[id]?.foreground == true }

    func receive(_ url: URL, sceneID: UUID?, identity: LibraryAccountIdentity?) -> ReceiveDisposition {
        if let identity { accountDidChange(from: resolvedIdentity, to: identity) }
        let ext = url.pathExtension.lowercased()
        guard ext == "epub" || ext == "pdf" else { setError("Rishi can open EPUB and PDF files.", preferredSceneID: sceneID); return .unsupported }
        let boundIdentity = identity ?? resolvedIdentity
        let key = url.standardizedFileURL.absoluteString
        let now = clock.now()
        if let id = inFlightByURL[key], let entry = entries[id], entry.identity == boundIdentity, !entry.revoked { return .duplicate }
        if let completedEntry = completed[key], completedEntry.identity == boundIdentity, completedEntry.until > now { return .duplicate }
        guard entries.count < limits.entries else { setError("Too many files are waiting. Try again after the current import finishes.", preferredSceneID: sceneID); return .failed }
        let didStart = startAccessing(url)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let declared = (attributes?[.size] as? NSNumber)?.int64Value ?? limits.perFileBytes
        guard declared >= 0, declared <= limits.perFileBytes else {
            if didStart { stopAccessing(url) }
            setError("This file is too large to import right now.", preferredSceneID: sceneID); return .failed
        }
        sequence &+= 1
        let id = UUID()
        guard byteBudget.reserve(declared, for: id) else {
            if didStart { stopAccessing(url) }
            setError("Too many files are waiting. Try again after the current import finishes.", preferredSceneID: sceneID); return .failed
        }
        let name = Self.safeBasename(url.lastPathComponent, preservingExtension: ext)
        let entry = Entry(id: id, sequence: sequence, sourceKey: key, safeName: name, originScene: sceneID, identity: boundIdentity, state: .staging, reservedBytes: declared, scopeStarted: didStart, expiresAt: boundIdentity == nil ? now + limits.signedOutExpiry : nil)
        entries[id] = entry; arrival.append(id); inFlightByURL[key] = id
        publishPending()
        let destination = inboxRoot.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
        let stager = self.stager
        let cancellation = IncomingBookCancellationFlag()
        cancellations[id] = cancellation
        Task { [self] in
            do {
                _ = try await stager.stage(source: url, destination: destination, maximumBytes: self.limits.perFileBytes, initiallyReservedBytes: declared, cancellation: cancellation, reserveGrowth: { [budget = self.byteBudget] growth in budget.reserve(growth, for: id) })
                if didStart { self.stopAccessing(url) }
                self.stagingFinished(id: id, destination: destination, error: nil)
            } catch {
                if didStart { self.stopAccessing(url) }
                self.stagingFinished(id: id, destination: destination, error: error)
            }
        }
        return .accepted
    }

    func accountDidChange(from: LibraryAccountIdentity?, to: LibraryAccountIdentity?) {
        guard resolvedIdentity != to else { return }
        for id in Array(prepareWaiters.keys) { resolvePrepareWaiter(id, result: .denied) }
        let outgoing = resolvedIdentity ?? from
        resolvedIdentity = to
        completed.removeAll()
        if let outgoing { pendingNotices.removeAll { $0.identity == outgoing } }
        if presentationError != nil, presentationErrorIdentity != nil, presentationErrorIdentity != to {
            presentationError = nil
            presentationErrorIdentity = nil
            preferredErrorSceneID = nil
        }
        promotePendingNotice()
        if let outgoing {
            for id in arrival {
                guard var entry = entries[id], entry.identity == outgoing else { continue }
                entry.revoked = true
                cancellations[id]?.cancel()
                inFlightByURL.removeValue(forKey: entry.sourceKey)
                switch entry.state {
                case .ready: removeEntry(id)
                case .staging, .importing: entries[id] = entry
                case .queued, .finished: removeEntry(id)
                }
            }
        }
        for (id, var entry) in entries where entry.identity == nil {
            entry.identity = to
            entry.expiresAt = nil
            entries[id] = entry
        }
        for (id, host) in hosts where host.identity != to { hosts.removeValue(forKey: id) }
        publishPending(); requestDrain()
    }

    @discardableResult func registerRootScene(id: UUID, isForeground: Bool) -> UUID { recency &+= 1; let token = UUID(); roots[id] = RootHost(registrationToken: token, foreground: isForeground, recency: recency); electRoot(); return token }
    func unregisterRootScene(id: UUID, registrationToken: UUID? = nil) { guard let root = roots[id], registrationToken == nil || root.registrationToken == registrationToken else { return }; roots.removeValue(forKey: id); electRoot() }
    func setRootSceneForeground(id: UUID, isForeground: Bool, registrationToken: UUID? = nil) { guard var root = roots[id], registrationToken == nil || root.registrationToken == registrationToken else { return }; recency &+= 1; root.foreground = isForeground; root.recency = recency; roots[id] = root; if isForeground, presentationError != nil { preferredErrorSceneID = id }; electRoot(); if isForeground { foregroundSceneDidActivate() } }
    func foregroundSceneDidActivate() { sweepExpired(); requestDrain() }

    @discardableResult func registerScene(id: UUID, identity: LibraryAccountIdentity?, readiness: IncomingBookPresentationReadiness, currentIdentity: @escaping @MainActor () -> LibraryAccountIdentity?, prepareForClaim: @escaping @MainActor () async -> Bool, importOwned: @escaping @Sendable (URL) async -> ImportCoordinator.ImportOutcome, refresh: @escaping @MainActor () async -> Void, open: @escaping @MainActor (Book) -> IncomingBookOpenResult, importAttemptID: @escaping @MainActor () -> UUID? = { nil }, didImportSuccessfully: @escaping @MainActor (Book, LibraryAccountIdentity, UUID?) -> Void = { _, _, _ in }) -> UUID {
        recency &+= 1
        resolvePrepareWaiter(id, result: .denied)
        let token = UUID()
        hosts[id] = Host(registrationToken: token, identity: identity, readiness: readiness, currentIdentity: currentIdentity, importAttemptID: importAttemptID, didImportSuccessfully: didImportSuccessfully, prepareForClaim: prepareForClaim, importOwned: importOwned, refresh: refresh, open: open, foreground: false, recency: recency)
        requestDrain()
        return token
    }
    func unregisterScene(id: UUID, registrationToken: UUID? = nil) {
        guard let host = hosts[id], registrationToken == nil || host.registrationToken == registrationToken else { return }
        resolvePrepareWaiter(id, result: .denied); hosts.removeValue(forKey: id); requestDrain()
    }
    func setSceneForeground(id: UUID, isForeground: Bool, registrationToken: UUID? = nil) {
        guard var host = hosts[id], registrationToken == nil || host.registrationToken == registrationToken else { return }
        recency &+= 1
        host.foreground = isForeground
        host.recency = recency
        hosts[id] = host
        if isForeground { requestDrain() }
    }

    func dismissError() {
        guard presentationError != nil else { return }
        dismissError(id: presentationError!.id)
    }
    func dismissError(id: UUID) {
        guard presentationError?.id == id else { return }
        presentationError = nil
        presentationErrorIdentity = nil
        preferredErrorSceneID = nil
        promotePendingNotice()
        publishPending()
        requestDrain()
    }
    func requestDrain() {
        drainWakeRequested = true
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        drainWakeRequested = false
        defer { drainTask = nil; if drainWakeRequested { requestDrain() } }
        while !Task.isCancelled {
            sweepExpired()
            guard presentationError == nil else { return }
            guard let id = arrival.first(where: { entries[$0].map { !$0.revoked } ?? false }), let entry = entries[id] else { return }
            guard let identity = entry.identity, identity == resolvedIdentity else { return }
            guard let hostID = electedHost(for: entry, identity: identity), let host = hosts[hostID] else { return }
            switch entry.state {
            case .queued:
                guard host.readiness.isReady(for: identity) || host.readiness.isReadyForPreclaim(for: identity) else { return }
                if !host.readiness.isReady(for: identity) {
                    let prepared = await prepareForClaim(hostID, host: host)
                    if prepared == .timedOut, hosts[hostID]?.registrationToken == host.registrationToken, resolvedIdentity == identity {
                        setError("Rishi couldn't close the first book prompt. Dismiss it and try opening the file again.", preferredSceneID: entry.originScene)
                        return
                    }
                    guard prepared == .ready, hosts[hostID]?.registrationToken == host.registrationToken, host.currentIdentity() == identity, host.readiness.isReady(for: identity) else { return }
                }
                guard presentationError == nil, host.currentIdentity() == identity, host.readiness.isReady(for: identity), var claimed = entries[id], !claimed.revoked else { return }
                claimed.state = .importing; entries[id] = claimed; publishPending()
                guard let source = claimed.stagedURL else { fail(id, message: "The selected file could not be read."); continue }
                let importAttemptID = host.importAttemptID()
                let outcome = await host.importOwned(source)
                guard let currentEntry = entries[id] else { continue }
                if currentEntry.revoked { removeEntry(id); continue }
                guard resolvedIdentity == identity else { removeEntry(id); continue }
                try? fileManager.removeItem(at: source.deletingLastPathComponent())
                releaseReservation(id)
                if let book = outcome.book, outcome.error == nil {
                    if book.userId == identity.userID {
                        host.didImportSuccessfully(book, identity, importAttemptID)
                    }
                    let now = clock.now()
                    if var result = entries[id] { result.state = .ready(book, identity, now + limits.readyLifetime, 0); result.stagedURL = nil; entries[id] = result }
                    publishPending()
                    if let currentHost = hosts[hostID], currentHost.identity == identity { await currentHost.refresh() }
                } else {
                    fail(id, message: outcome.error ?? "Rishi couldn't import this file. Try importing it again.")
                }
            case .ready(let book, let boundIdentity, let deadline, let attempts):
                guard boundIdentity == identity else { removeEntry(id); continue }
                let now = clock.now()
                guard now < deadline, attempts < limits.openAttempts else { failReady(id); continue }
                guard host.currentIdentity() == identity, host.readiness.isReady(for: identity), presentationError == nil else { return }
                let result = host.open(book)
                if result == .presented || result == .focusedExisting {
                    let until = now + limits.duplicateWindow
                    completed[entry.sourceKey] = (identity, until)
                    removeEntry(id)
                } else if var retry = entries[id] {
                    if attempts + 1 >= limits.openAttempts { failReady(id); continue }
                    retry.state = .ready(book, identity, deadline, attempts + 1); entries[id] = retry
                    return
                }
                publishPending()
            case .staging, .importing, .finished: return
            }
        }
    }

    private func electedHost(for entry: Entry, identity: LibraryAccountIdentity) -> UUID? {
        func eligible(_ host: Host) -> Bool {
            guard host.identity == identity, host.foreground else { return false }
            switch entry.state {
            case .queued:
                return host.readiness.isReady(for: identity) || host.readiness.isReadyForPreclaim(for: identity)
            case .ready:
                return host.readiness.isReady(for: identity)
            case .staging, .importing, .finished:
                return false
            }
        }
        if let origin = entry.originScene, let host = hosts[origin], eligible(host) { return origin }
        return hosts.filter { eligible($0.value) }.max { $0.value.recency < $1.value.recency }?.key
    }
    private func prepareForClaim(_ hostID: UUID, host: Host) async -> ClaimPreparation {
        await withCheckedContinuation { continuation in
            prepareWaiters[hostID] = continuation
            prepareTimeouts[hostID] = Task { @MainActor in
                do { try await clock.sleep(for: limits.dismissalTimeout) } catch { return }
                resolvePrepareWaiter(hostID, result: .timedOut)
            }
            Task { @MainActor in
                let result = await host.prepareForClaim()
                resolvePrepareWaiter(hostID, result: result ? .ready : .denied)
            }
        }
    }
    private func resolvePrepareWaiter(_ hostID: UUID, result: ClaimPreparation) {
        guard let continuation = prepareWaiters.removeValue(forKey: hostID) else { return }
        prepareTimeouts.removeValue(forKey: hostID)?.cancel()
        continuation.resume(returning: result)
    }
    private func stagingFinished(id: UUID, destination: URL, error: Error?) {
        guard var entry = entries[id], !entry.revoked else { try? fileManager.removeItem(at: destination.deletingLastPathComponent()); if let entry = entries[id] { removeEntry(id) }; return }
        if let error { try? fileManager.removeItem(at: destination.deletingLastPathComponent()); fail(id, message: Self.message(for: error)); return }
        entry.stagedURL = destination; entry.state = .queued; entries[id] = entry
        requestDrain()
    }
    private func releaseReservation(_ id: UUID) { byteBudget.release(id); if var entry = entries[id] { entry.reservedBytes = 0; entries[id] = entry } }
    private func fail(_ id: UUID, message: String) { if let url = entries[id]?.stagedURL { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }; setError(message, preferredSceneID: entries[id]?.originScene); removeEntry(id); requestDrain() }
    private func failReady(_ id: UUID) { let sceneID = entries[id]?.originScene; removeEntry(id); setError("Book added. Open it from your Library.", preferredSceneID: sceneID) }
    private func removeEntry(_ id: UUID) { guard let entry = entries.removeValue(forKey: id) else { return }; byteBudget.release(id); cancellations.removeValue(forKey: id); if inFlightByURL[entry.sourceKey] == id { inFlightByURL.removeValue(forKey: entry.sourceKey) }; if let url = entry.stagedURL { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }; arrival.removeAll { $0 == id }; publishPending() }
    private func setError(_ message: String, preferredSceneID: UUID? = nil) {
        let notice = PendingNotice(identity: resolvedIdentity, message: message, preferredSceneID: preferredSceneID)
        guard presentationError == nil else {
            enqueuePendingNotice(notice)
            return
        }
        presentationError = PresentationError(message: message)
        presentationErrorIdentity = notice.identity
        preferredErrorSceneID = preferredSceneID
        publishPending()
    }
    private func enqueuePendingNotice(_ notice: PendingNotice) {
        guard !pendingNotices.contains(where: { $0.identity == notice.identity && $0.message == notice.message }) else { return }
        let limit = max(1, limits.entries)
        if pendingNotices.count == limit { pendingNotices.removeFirst() }
        pendingNotices.append(notice)
    }
    private func promotePendingNotice() {
        while !pendingNotices.isEmpty {
            let notice = pendingNotices.removeFirst()
            guard notice.identity == resolvedIdentity || notice.identity == nil else { continue }
            presentationError = PresentationError(message: notice.message)
            presentationErrorIdentity = notice.identity
            preferredErrorSceneID = notice.preferredSceneID
            return
        }
    }
    private func publishPending() { let value = entries.values.contains { !$0.revoked }; if value != hasPendingFile { hasPendingFile = value }; revision &+= 1; electRoot(); scheduleMaintenance() }
    private func electRoot() {
        if presentationError != nil, let preferredErrorSceneID, roots[preferredErrorSceneID]?.foreground == true {
            selectedRootErrorSceneID = preferredErrorSceneID
        } else {
            selectedRootErrorSceneID = roots.filter { $0.value.foreground }.max { $0.value.recency < $1.value.recency }?.key
        }
    }
    private func sweepExpired() {
        let now = clock.now()
        for (id, entry) in entries {
            if entry.expiresAt.map({ $0 <= now }) == true {
                if case .staging = entry.state {
                    var revoked = entry
                    revoked.revoked = true
                    revoked.expiresAt = nil
                    entries[id] = revoked
                    cancellations[id]?.cancel()
                    if inFlightByURL[entry.sourceKey] == id { inFlightByURL.removeValue(forKey: entry.sourceKey) }
                    publishPending()
                } else {
                    removeEntry(id)
                }
                continue
            }
            if case .ready(_, _, let deadline, _) = entry.state, deadline <= now { failReady(id) }
        }
        completed = completed.filter { $0.value.until > now }
    }
    private func scheduleMaintenance() {
        expiryTask?.cancel()
        var deadlines = entries.values.compactMap(\.expiresAt)
        deadlines.append(contentsOf: entries.values.compactMap { entry in if case .ready(_, _, let deadline, _) = entry.state { deadline } else { nil } })
        deadlines.append(contentsOf: completed.values.map(\.until))
        guard let deadline = deadlines.min() else { return }
        let delay = max(.zero, deadline - clock.now())
        expiryTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.sweepExpired()
            self.requestDrain()
        }
    }
    private func isFinished(_ state: State) -> Bool { if case .finished = state { return true }; return false }
    private static func safeBasename(_ value: String, preservingExtension fileExtension: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
        let stem = URL(fileURLWithPath: leaf).deletingPathExtension().lastPathComponent
        let scalars = stem.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }
        let suffix = ".\(fileExtension.lowercased())"
        let stemLimit = max(1, 180 - suffix.unicodeScalars.count)
        let trimmed = String(String.UnicodeScalarView(scalars.prefix(stemLimit)))
        return "\(trimmed.isEmpty ? "Incoming Book" : trimmed)\(suffix)"
    }
    private static func message(for error: Error) -> String {
        if error is CancellationError { return "The file import was cancelled." }
        if let stagingError = error as? IncomingBookStagingError {
            switch stagingError { case .fileTooLarge, .aggregateLimit: return "This file is too large to import right now."; case .unreadable: return "Rishi couldn't read this file. Check that it is downloaded, then try again." }
        }
        return "Rishi couldn't read this file. Check that it is downloaded, then try again."
    }
}

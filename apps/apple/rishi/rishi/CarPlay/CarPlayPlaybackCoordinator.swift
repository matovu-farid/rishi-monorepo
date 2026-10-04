import Foundation

@MainActor
protocol CarPlayPlaybackDriving: AnyObject {
    var activeBookID: BookID? { get }
    var onSourceUnavailable: (@MainActor (BookID, CarPlayAccountSnapshot) -> Void)? { get set }
    func start(bookID: BookID) async throws
    func toggle() async
    func pause() async
    func resume() async
    func next() async
    func previous() async
    func stop() async
    func releaseCarPlayHost() async
    func accountDidChange() async
}

enum CarPlayPlaybackDriverError: Error, Equatable {
    case bookUnavailable
    case unsupportedFormat
    case fileMissing
    case publicationUnavailable
    case staleAccount
    case sourceUnavailable
    case startFailed
}

@MainActor
final class ReadAloudCarPlayDriver: CarPlayPlaybackDriving {
    enum InvalidationDisposition: Equatable {
        case rejectPendingStart
        case stopActiveReader
        case ignoreStale
    }

    private let services: BootstrappedServices
    private let owner: ReadAloudPlaybackOwner
    private let accountSnapshot: @MainActor @Sendable () -> CarPlayAccountSnapshot?
    private let host: UUID
    private var startedBookID: BookID?
    private var sourceObservations: [UUID: SourceObservation] = [:]
    private var activeSourceObservationID: UUID?
    private(set) var sourceUnavailableBookID: BookID?
    var onSourceUnavailable: (@MainActor (BookID, CarPlayAccountSnapshot) -> Void)?

    private final class SourceObservation {
        let bookID: BookID
        let account: CarPlayAccountSnapshot
        weak var reader: ReaderViewModel?
        var task: Task<Void, Never>?

        init(bookID: BookID, account: CarPlayAccountSnapshot) {
            self.bookID = bookID
            self.account = account
        }
    }

    static func activeBookID(
        ownerHost: UUID?,
        carPlayHost: UUID,
        startedBookID: BookID?
    ) -> BookID? {
        ownerHost == carPlayHost ? startedBookID : nil
    }

    static func readingPermit(
        from sourceAccess: BookSourceAccess,
        bookID: BookID,
        account: CarPlayAccountSnapshot
    ) -> BookReadingPermit? {
        guard case let .account(permit) = sourceAccess,
              permit.ownerID == account.userID,
              permit.accountGeneration == account.generation,
              permit.bookID == bookID else { return nil }
        return permit
    }

    static func invalidationDisposition(
        invalidatedObservationID: UUID,
        activeObservationID: UUID?,
        accountIsCurrent: Bool
    ) -> InvalidationDisposition {
        guard accountIsCurrent else { return .ignoreStale }
        return activeObservationID == invalidatedObservationID
            ? .stopActiveReader
            : .rejectPendingStart
    }

    var activeBookID: BookID? {
        Self.activeBookID(
            ownerHost: owner.activeHost,
            carPlayHost: host,
            startedBookID: startedBookID
        )
    }

    init(
        services: BootstrappedServices,
        owner: ReadAloudPlaybackOwner,
        host: UUID = UUID(),
        accountSnapshot: @escaping @MainActor @Sendable () -> CarPlayAccountSnapshot?
    ) {
        self.services = services
        self.owner = owner
        self.host = host
        self.accountSnapshot = accountSnapshot
    }

    func start(bookID: BookID) async throws {
        guard let captured = accountSnapshot() else {
            throw CarPlayPlaybackDriverError.staleAccount
        }
        guard let book = try await services.library.bookStore.book(bookID) else {
            throw CarPlayPlaybackDriverError.bookUnavailable
        }
        guard book.userId == captured.userID else {
            throw CarPlayPlaybackDriverError.bookUnavailable
        }
        guard accountSnapshot() == captured else {
            throw CarPlayPlaybackDriverError.staleAccount
        }
        guard book.formatType == .epub else {
            throw CarPlayPlaybackDriverError.unsupportedFormat
        }
        let sourceLease: BookSourceLease
        do {
            sourceLease = try await services.library.bookSourceRegistry.acquireReadableSource(for: book)
        } catch {
            guard accountSnapshot() == captured else {
                throw CarPlayPlaybackDriverError.staleAccount
            }
            throw CarPlayPlaybackDriverError.sourceUnavailable
        }
        guard let readingPermit = Self.readingPermit(
            from: sourceLease.access,
            bookID: book.id,
            account: captured
        ),
              accountSnapshot() == captured else {
            throw CarPlayPlaybackDriverError.staleAccount
        }
        guard FileManager.default.fileExists(atPath: sourceLease.url.path) else {
            throw CarPlayPlaybackDriverError.fileMissing
        }
        let observationID = observeInvalidation(of: sourceLease, bookID: book.id, account: captured)
        defer {
            if activeSourceObservationID != observationID {
                cancelInvalidationObservation(observationID)
            }
        }

        let scopedPositionStore = ScopedPositionStore(
            base: services.library.positionStore,
            mutations: services.library.scopedMutationStore,
            permit: readingPermit,
            originatingSource: sourceLease.sourceAccessPermit,
            sourceEffects: sourceLease.effectAuthority
        )

        let vm = ReaderViewModel.make(
            book: book,
            userId: captured.userID,
            positionStore: scopedPositionStore,
            sourceLease: sourceLease,
            unpackedCache: services.library.epubUnpackedCache
        )
        sourceObservations[observationID]?.reader = vm
        let loadAdmission: SourceEffectAdmission
        do {
            loadAdmission = try sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit)
        } catch {
            throw CarPlayPlaybackDriverError.sourceUnavailable
        }
        await vm.load()
        loadAdmission.release()
        guard !isInvalidated(observationID), sourceIsAvailable(sourceLease) else {
            throw CarPlayPlaybackDriverError.sourceUnavailable
        }
        guard accountSnapshot() == captured else {
            throw CarPlayPlaybackDriverError.staleAccount
        }
        guard vm.publication != nil else {
            throw CarPlayPlaybackDriverError.publicationUnavailable
        }

        let controller = owner.makeController(
            userId: captured.userID,
            bookFileStorage: services.library.bookFileStorage,
            onReadAloudPositionChange: { locator in
                vm.didChangeReadAloudLocation(locator)
            },
            onPersistReadAloudPosition: { locator in
                vm.didChangeReadAloudLocation(locator)
                await vm.flush()
            }
        )
        guard !isInvalidated(observationID), sourceIsAvailable(sourceLease) else {
            throw CarPlayPlaybackDriverError.sourceUnavailable
        }
        guard await owner.start(controller: controller, reader: vm, host: host) else {
            throw CarPlayPlaybackDriverError.startFailed
        }
        let previousObservationID = activeSourceObservationID
        activeSourceObservationID = observationID
        sourceUnavailableBookID = nil
        guard accountSnapshot() == captured else {
            await stop()
            throw CarPlayPlaybackDriverError.staleAccount
        }
        startedBookID = book.id
        if let previousObservationID, previousObservationID != observationID {
            cancelInvalidationObservation(previousObservationID)
        }
        guard !isInvalidated(observationID), sourceUnavailableBookID != book.id else {
            await sourceDidInvalidate(observationID)
            throw CarPlayPlaybackDriverError.sourceUnavailable
        }
    }

    func toggle() async {
        guard owner.activeHost == host else {
            startedBookID = nil
            return
        }
        await owner.activeController?.togglePlayback()
    }

    func pause() async {
        guard owner.activeHost == host else { return }
        await owner.activeController?.pause()
    }

    func resume() async {
        guard owner.activeHost == host else { return }
        await owner.activeController?.resume()
    }

    func next() async {
        guard owner.activeHost == host else { return }
        await owner.activeController?.next()
    }

    func previous() async {
        guard owner.activeHost == host else { return }
        await owner.activeController?.previous()
    }

    func stop() async {
        if let observationID = activeSourceObservationID,
           let reader = sourceObservations[observationID]?.reader {
            _ = await owner.stop(reader: reader)
            if activeSourceObservationID == observationID {
                activeSourceObservationID = nil
            }
            cancelInvalidationObservation(observationID)
        } else if owner.activeHost == host {
            await owner.activeController?.stop()
        }
        startedBookID = nil
    }

    func releaseCarPlayHost() async {
        await owner.release(host: host)
        let observationIDs = Array(sourceObservations.keys)
        observationIDs.forEach(cancelInvalidationObservation)
        activeSourceObservationID = nil
        startedBookID = nil
    }

    func accountDidChange() async {
        let observationIDs = Array(sourceObservations.keys)
        observationIDs.forEach(cancelInvalidationObservation)
        activeSourceObservationID = nil
        startedBookID = nil
        sourceUnavailableBookID = nil
    }

    private func observeInvalidation(
        of sourceLease: BookSourceLease,
        bookID: BookID,
        account: CarPlayAccountSnapshot
    ) -> UUID {
        let observationID = UUID()
        let observation = SourceObservation(bookID: bookID, account: account)
        sourceObservations[observationID] = observation
        let invalidation = sourceLease.invalidation
        observation.task = Task { @MainActor [weak self] in
            for await _ in invalidation {
                guard !Task.isCancelled else { return }
                self?.invalidatedSourceIDs.insert(observationID)
                await self?.sourceDidInvalidate(observationID)
                return
            }
        }
        return observationID
    }

    private func sourceDidInvalidate(_ observationID: UUID) async {
        guard let observation = sourceObservations[observationID] else { return }
        let disposition = Self.invalidationDisposition(
            invalidatedObservationID: observationID,
            activeObservationID: activeSourceObservationID,
            accountIsCurrent: accountSnapshot() == observation.account
        )
        guard disposition != .ignoreStale else {
            cancelInvalidationObservation(observationID)
            return
        }
        guard disposition == .stopActiveReader,
              let reader = observation.reader else { return }

        let stopped = await owner.stop(reader: reader)
        guard stopped, activeSourceObservationID == observationID else {
            cancelInvalidationObservation(observationID)
            return
        }
        activeSourceObservationID = nil
        startedBookID = nil
        sourceUnavailableBookID = observation.bookID
        cancelInvalidationObservation(observationID)
        onSourceUnavailable?(observation.bookID, observation.account)
    }

    private func isInvalidated(_ observationID: UUID) -> Bool {
        invalidatedSourceIDs.contains(observationID)
    }

    private func sourceIsAvailable(_ sourceLease: BookSourceLease) -> Bool {
        guard let admission = try? sourceLease.effectAuthority.admit(sourceLease.sourceAccessPermit) else {
            return false
        }
        admission.release()
        return true
    }

    private var invalidatedSourceIDs: Set<UUID> = []

    private func cancelInvalidationObservation(_ observationID: UUID) {
        sourceObservations.removeValue(forKey: observationID)?.task?.cancel()
        invalidatedSourceIDs.remove(observationID)
    }
}

enum CarPlayPlaybackSelectionResult: Equatable {
    case started
    case toggled
    case entitlementRequired
    case signedOut
    case staleAccount
}

@MainActor
final class CarPlayPlaybackCoordinator {
    private let driver: any CarPlayPlaybackDriving
    private let accountSnapshot: @MainActor @Sendable () -> CarPlayAccountSnapshot?
    private let entitlementGate: @MainActor @Sendable () async -> Bool
    private var capturedSnapshot: CarPlayAccountSnapshot?
    private var selectionGeneration: UInt64 = 0

    init(
        driver: any CarPlayPlaybackDriving,
        accountSnapshot: @escaping @MainActor @Sendable () -> CarPlayAccountSnapshot?,
        entitlementGate: @escaping @MainActor @Sendable () async -> Bool
    ) {
        self.driver = driver
        self.accountSnapshot = accountSnapshot
        self.entitlementGate = entitlementGate
    }

    func select(bookID: BookID) async throws -> CarPlayPlaybackSelectionResult {
        selectionGeneration &+= 1
        let requestGeneration = selectionGeneration
        guard let snapshot = accountSnapshot() else { return .signedOut }
        capturedSnapshot = snapshot
        if driver.activeBookID == bookID {
            await driver.toggle()
            guard requestGeneration == selectionGeneration,
                  accountSnapshot() == snapshot else { return .staleAccount }
            return .toggled
        }
        guard await entitlementGate() else { return .entitlementRequired }
        guard requestGeneration == selectionGeneration,
              accountSnapshot() == snapshot else { return .staleAccount }
        do {
            try await driver.start(bookID: bookID)
        } catch {
            throw error
        }
        guard requestGeneration == selectionGeneration,
              accountSnapshot() == snapshot,
              driver.activeBookID == bookID else {
            // The driver owns a host-scoped session. Stop only if that host
            // still owns the shared controller; a phone handoff is preserved.
            if driver.activeBookID == bookID {
                await driver.stop()
            }
            return .staleAccount
        }
        return .started
    }

    func pause() async {
        guard isCurrentAccount() else { return }
        await driver.pause()
    }
    func resume() async {
        guard isCurrentAccount() else { return }
        await driver.resume()
    }
    func next() async {
        guard isCurrentAccount() else { return }
        await driver.next()
    }
    func previous() async {
        guard isCurrentAccount() else { return }
        await driver.previous()
    }
    func stop() async {
        guard isCurrentAccount() else { return }
        await driver.stop()
    }

    private func isCurrentAccount() -> Bool {
        guard let capturedSnapshot else { return false }
        return accountSnapshot() == capturedSnapshot
    }

    func disconnect() async {
        selectionGeneration &+= 1
        capturedSnapshot = nil
        await driver.releaseCarPlayHost()
    }

    func accountDidChange() async {
        selectionGeneration &+= 1
        capturedSnapshot = nil
        await driver.accountDidChange()
    }
}

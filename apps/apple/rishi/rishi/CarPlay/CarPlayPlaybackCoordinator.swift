import Foundation

@MainActor
protocol CarPlayPlaybackDriving: AnyObject {
    var activeBookID: BookID? { get }
    func start(bookID: BookID) async throws
    func toggle() async
    func pause() async
    func resume() async
    func next() async
    func previous() async
    func stop() async
    func releaseCarPlayHost() async
}

enum CarPlayPlaybackDriverError: Error, Equatable {
    case bookUnavailable
    case unsupportedFormat
    case fileMissing
    case publicationUnavailable
    case staleAccount
    case startFailed
}

@MainActor
final class ReadAloudCarPlayDriver: CarPlayPlaybackDriving {
    private let services: BootstrappedServices
    private let owner: ReadAloudPlaybackOwner
    private let accountSnapshot: @MainActor @Sendable () -> CarPlayAccountSnapshot?
    private let host: UUID
    private var startedBookID: BookID?

    static func activeBookID(
        ownerHost: UUID?,
        carPlayHost: UUID,
        startedBookID: BookID?
    ) -> BookID? {
        ownerHost == carPlayHost ? startedBookID : nil
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
        let documentURL = services.library.bookFileStorage.absoluteFileURL(for: book)
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            throw CarPlayPlaybackDriverError.fileMissing
        }

        let vm = ReaderViewModel(
            book: book,
            userId: captured.userID,
            documentURL: documentURL,
            positionStore: services.library.positionStore
        )
        await vm.load()
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
        guard await owner.start(controller: controller, reader: vm, host: host) else {
            throw CarPlayPlaybackDriverError.startFailed
        }
        guard accountSnapshot() == captured else {
            await stop()
            throw CarPlayPlaybackDriverError.staleAccount
        }
        startedBookID = book.id
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
        guard owner.activeHost == host else {
            startedBookID = nil
            return
        }
        await owner.activeController?.stop()
        startedBookID = nil
    }

    func releaseCarPlayHost() async {
        await owner.release(host: host)
        startedBookID = nil
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
}

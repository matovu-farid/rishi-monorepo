import Foundation
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth
import RishiDB
import RishiLibrary
import RishiReader
import RishiSync

/// Composition root for the rishi app. Constructed once by `rishiApp.init()`.
///
/// Holds references to every long-lived service the app needs. Actors do their
/// own isolation; this `@MainActor` class is just the holder that SwiftUI can
/// reach into synchronously to fetch them.
@MainActor
final class AppDependencies {

    // Auth + transport
    let keychain: KeychainSessionStore
    let tokenProvider: RishiAuthTokenProvider
    let workerClient: WorkerClient
    let siwaPresenter: SystemSiwaPresenter
    let googlePresenter: SystemGoogleWebAuthPresenter
    let siwaCoordinator: SignInWithAppleCoordinator
    let googleCoordinator: GoogleSignInCoordinator
    let authService: RishiAuthService

    // Persistence + library
    let dbQueue: DatabaseQueue
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let libraryViewModel: LibraryViewModel

    // Reader
    let readerSettingsStore: any ReaderSettingsStore

    // Sync (Phase 7 — composition root for the sync engine + background coord)
    let syncMetadataStore: GRDBSyncMetadataStore
    let syncQueue: SyncQueue
    let syncStatus: SyncStatus
    let bookUploader: BookUploader
    let positionUploader: PositionUploader
    let highlightUploader: HighlightUploader
    let remoteChangeFetcher: RemoteChangeFetcher
    let changeApplier: ChangeApplier
    let syncEngine: SyncEngine
    let backgroundTaskCoordinator: BackgroundTaskCoordinator
    let apnsDeviceRegistrar: APNsDeviceRegistrar

    /// Cached user id pumped in by RootView after the auth session resolves.
    /// LibraryViewModel reads this synchronously from its currentUserId
    /// closure so refresh() does not need to hop into the auth actor.
    var cachedUserId: UserID? {
        get { userIdBox.value }
        set { userIdBox.value = newValue }
    }

    init() {
        // Worker base URL (override via env for staging tests).
        let baseURLString = ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!

        // 1. Keychain — single instance backing the token provider AND the auth service.
        let keychain = KeychainSessionStore()
        self.keychain = keychain

        // 2. Token provider reads from the same keychain.
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)
        self.tokenProvider = tokenProvider

        // 3. WorkerClient with dev-bypass gated to DEBUG only.
        #if DEBUG
        let devBypassEnabled = DevBypassConfig.isEnabled
        #else
        let devBypassEnabled = false
        #endif
        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            devBypassEnabled: devBypassEnabled
        )
        self.workerClient = workerClient

        // 4. Presenters (must be constructed on main actor — we ARE the main actor here).
        let siwaPresenter = SystemSiwaPresenter()
        let googlePresenter = SystemGoogleWebAuthPresenter()
        self.siwaPresenter = siwaPresenter
        self.googlePresenter = googlePresenter

        // 5. Coordinators wrap the presenters + worker client.
        let siwaCoordinator = SignInWithAppleCoordinator(
            workerClient: workerClient,
            presenter: siwaPresenter
        )
        let googleCoordinator = GoogleSignInCoordinator(
            workerClient: workerClient,
            presenter: googlePresenter,
            baseURL: baseURL,
            callbackScheme: "rishi"
        )
        self.siwaCoordinator = siwaCoordinator
        self.googleCoordinator = googleCoordinator

        // 6. Auth service aggregates everything.
        let authService = RishiAuthService(
            workerClient: workerClient,
            siwaCoordinator: siwaCoordinator,
            googleCoordinator: googleCoordinator,
            keychain: keychain
        )
        self.authService = authService

        // 7. Persistence layer (GRDB queue under Documents).
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("rishi.sqlite")
        let dbQueue: DatabaseQueue
        do {
            dbQueue = try RishiDB.makeDatabaseQueue(at: dbURL)
        } catch {
            fatalError("Failed to open rishi.sqlite at \(dbURL): \(error)")
        }
        self.dbQueue = dbQueue

        // 8. Stores.
        let bookStore = GRDBBookStore(dbQueue: dbQueue)
        let positionStore = GRDBPositionStore(dbQueue: dbQueue)
        let highlightStore = GRDBHighlightStore(dbQueue: dbQueue)
        self.bookStore = bookStore
        self.positionStore = positionStore
        self.highlightStore = highlightStore

        // 8b. Reader settings (per-book theme persistence via UserDefaults).
        self.readerSettingsStore = UserDefaultsReaderSettingsStore()

        // 9. Library file storage (cover extractors for the two v1 formats).
        let bookFileStorage = BookFileStorage(
            rootURL: documentsURL,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(),
                "epub": EpubCoverExtractor(),
            ]
        )
        self.bookFileStorage = bookFileStorage

        // 9b. Sync — composition root for the engine + background coordinator.
        //
        // Built BEFORE the ImportCoordinator so the coordinator's onBookImported
        // callback can route into `syncEngine.markBookDirty(_:)` for SYNC-01.
        let syncMetadataStore = GRDBSyncMetadataStore(dbQueue: dbQueue)
        self.syncMetadataStore = syncMetadataStore

        let syncQueue = SyncQueue(metadataStore: syncMetadataStore)
        self.syncQueue = syncQueue

        let syncStatus = SyncStatus()
        self.syncStatus = syncStatus

        let bookUploader = BookUploader(
            workerClient: workerClient,
            metadataStore: syncMetadataStore,
            fileStorage: bookFileStorage
        )
        let positionUploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: syncMetadataStore
        )
        let highlightUploader = HighlightUploader(
            workerClient: workerClient,
            highlightStore: highlightStore,
            metadataStore: syncMetadataStore
        )
        let remoteChangeFetcher = RemoteChangeFetcher(
            workerClient: workerClient,
            metadataStore: syncMetadataStore
        )
        let changeApplier = ChangeApplier(
            bookStore: bookStore,
            positionStore: positionStore,
            highlightStore: highlightStore,
            metadataStore: syncMetadataStore
        )
        self.bookUploader = bookUploader
        self.positionUploader = positionUploader
        self.highlightUploader = highlightUploader
        self.remoteChangeFetcher = remoteChangeFetcher
        self.changeApplier = changeApplier

        let syncEngine = SyncEngine(
            config: .init(),
            queue: syncQueue,
            metadataStore: syncMetadataStore,
            bookStore: bookStore,
            bookUploader: bookUploader,
            positionUploader: positionUploader,
            highlightUploader: highlightUploader,
            fetcher: remoteChangeFetcher,
            applier: changeApplier
        )
        self.syncEngine = syncEngine

        self.backgroundTaskCoordinator = BackgroundTaskCoordinator(engine: syncEngine)
        self.apnsDeviceRegistrar = APNsDeviceRegistrar(workerClient: workerClient)

        // 10. Import coordinator pulls the current user id from the auth service
        // at import time (handles sign-out / sign-in transitions correctly).
        // SYNC-01: every successful import fans into the sync engine so the
        // book uploads on the next wave.
        self.importCoordinator = ImportCoordinator(
            storage: bookFileStorage,
            currentUserId: {
                await authService.currentUser?.id
            },
            onBookImported: { [syncEngine] bookId in
                await syncEngine.markBookDirty(bookId)
            }
        )

        // 11. Sample-book installers (first-run alice.epub + sample.pdf).
        self.sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)
        self.sampleReaderInstaller = SampleReaderInstaller(storage: bookFileStorage)

        // 12. Library view model. `currentUserId` reads from a heap-allocated
        // box that RootView pumps via `cachedUserId`. We can't capture `self`
        // here (it's still mid-init), so we route through a tiny box and keep
        // a reference for AppDependencies's setter to update.
        let userIdBox = UserIdBox()
        self.userIdBox = userIdBox
        self.libraryViewModel = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: bookFileStorage,
            currentUserId: { userIdBox.value }
        )

        // 13. Bind the @Observable SyncStatus to the engine actor. Fire-and-forget
        //     Task because init can't await; the actor handles the hop.
        Task { [syncEngine, syncStatus] in
            await syncEngine.bind(status: syncStatus)
        }
    }

    private let userIdBox: UserIdBox

    var authServiceForEnvironment: any AuthService { authService }
}

/// Tiny @MainActor-isolated reference box so LibraryViewModel's currentUserId
/// closure can be constructed before `self` is fully initialised. The closure
/// captures the box (a reference type), AppDependencies mutates `box.value`,
/// and LibraryViewModel reads the latest value on every `currentUserId()` call.
@MainActor
private final class UserIdBox {
    var value: UserID? = nil
}

// MARK: - SwiftUI environment keys

private struct RishiAuthServiceKey: EnvironmentKey {
    static let defaultValue: (any AuthService)? = nil
}

extension EnvironmentValues {
    var rishiAuthService: (any AuthService)? {
        get { self[RishiAuthServiceKey.self] }
        set { self[RishiAuthServiceKey.self] = newValue }
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    @MainActor static let defaultValue: AppDependencies? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}

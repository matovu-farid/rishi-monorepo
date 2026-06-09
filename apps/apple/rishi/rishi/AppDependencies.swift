import Foundation
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth
import RishiDB
import RishiLibrary

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
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let libraryViewModel: LibraryViewModel

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
        self.bookStore = bookStore
        self.positionStore = positionStore

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

        // 10. Import coordinator pulls the current user id from the auth service
        // at import time (handles sign-out / sign-in transitions correctly).
        self.importCoordinator = ImportCoordinator(storage: bookFileStorage) {
            await authService.currentUser?.id
        }

        // 11. Sample-book installer (first-run alice.epub).
        self.sampleBookInstaller = SampleBookInstaller(storage: bookFileStorage)

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

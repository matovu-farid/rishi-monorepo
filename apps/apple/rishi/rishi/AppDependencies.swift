import Foundation
import SwiftUI
import RishiCore
import RishiAPI
import RishiAuth

/// Composition root for the rishi app. Constructed once by `rishiApp.init()`.
///
/// Holds references to every long-lived service the app needs. Actors do their
/// own isolation; this `@MainActor` class is just the holder that SwiftUI can
/// reach into synchronously to fetch them.
@MainActor
final class AppDependencies {

    let keychain: KeychainSessionStore
    let tokenProvider: RishiAuthTokenProvider
    let workerClient: WorkerClient
    let siwaPresenter: SystemSiwaPresenter
    let googlePresenter: SystemGoogleWebAuthPresenter
    let siwaCoordinator: SignInWithAppleCoordinator
    let googleCoordinator: GoogleSignInCoordinator
    let authService: RishiAuthService

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
        self.authService = RishiAuthService(
            workerClient: workerClient,
            siwaCoordinator: siwaCoordinator,
            googleCoordinator: googleCoordinator,
            keychain: keychain
        )
    }

    var authServiceForEnvironment: any AuthService { authService }
}

// MARK: - SwiftUI environment key

private struct RishiAuthServiceKey: EnvironmentKey {
    static let defaultValue: (any AuthService)? = nil
}

extension EnvironmentValues {
    var rishiAuthService: (any AuthService)? {
        get { self[RishiAuthServiceKey.self] }
        set { self[RishiAuthServiceKey.self] = newValue }
    }
}

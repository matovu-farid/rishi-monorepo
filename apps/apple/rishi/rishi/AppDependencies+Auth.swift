import Foundation
import RishiCore
import RishiAuth
import RishiAPI



extension AppDependencies {
    var keychain: KeychainSessionStore { services!.keychain }
    var tokenProvider: RishiAuthTokenProvider { services!.tokenProvider }
    var workerClient: WorkerClient { services!.workerClient }
    var siwaPresenter: SystemSiwaPresenter { services!.siwaPresenter }
    var siwaCoordinator: SignInWithAppleCoordinator { services!.siwaCoordinator }
    var authService: RishiAuthService { services!.authService }
    var authServiceForEnvironment: any AuthService { services!.authService }
}

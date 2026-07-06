import Foundation
import RishiCore
import RishiAuth
import RishiCore



extension AppDependencies {
    var keychain: KeychainSessionStore { services!.keychain }
    var tokenProvider: RishiAuthTokenProvider { services!.tokenProvider }
    var workerClient: WorkerClient { services!.workerClient }
    var siwaPresenter: SystemSiwaPresenter { services!.siwaPresenter }
}

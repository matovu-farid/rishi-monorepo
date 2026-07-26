import Foundation






extension AppDependencies {
    var keychain: KeychainSessionStore { services!.keychain }
    var tokenProvider: RishiAuthTokenProvider { services!.tokenProvider }
    var workerClient: WorkerClient { services!.workerClient }
    var siwaPresenter: SystemSiwaPresenter { services!.siwaPresenter }
}

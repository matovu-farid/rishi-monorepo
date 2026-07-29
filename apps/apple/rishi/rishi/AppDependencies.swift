import Foundation
import OSLog
import Observation















import SwiftUI

@MainActor
@Observable
final class AppDependencies {

    private(set) var services: BootstrappedServices?

    private var bootstrapTask: Task<Void, Never>?

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    let macCommandRouter = MacCommandRouter()

    let macAccountMenu = MacAccountMenuModel()

    var cachedUserId: UUID? {
        get { userIdBox.value }
        set { userIdBox.value = newValue }
    }

    public let userIdBox = UserIdBox()

    @ObservationIgnored
    private lazy var _backgroundSyncLifecycle = BackgroundSyncLifecycle(
        dependencies: self,
        userIdBox: self.userIdBox
    )

    var backgroundSyncLifecycle: BackgroundSyncLifecycle {
        _backgroundSyncLifecycle
    }

    nonisolated init() {

    }
    func setUserId(_ userId: UUID){
        self.userIdBox.setUserId(value: userId)
    }

    func bootstrap() async {
        if let inFlight = bootstrapTask {
            await inFlight.value
            return
        }
       
        

        let task = Task { [weak self] in
            guard let self else { return }
            let signpostId = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval(
                "cold-launch.bootstrap",
                id: signpostId
            )
            let built = await Self.makeServices(userIdBox: self.userIdBox)
            self.services = built
            await built.voiceSessionRegistry.recoverPersistedSession()
            Self.signposter.endInterval("cold-launch.bootstrap", state)
        }
        bootstrapTask = task
        await task.value
    }

    nonisolated private static func makeServices(
        userIdBox: UserIdBox
    ) async -> BootstrappedServices {
        await Task.detached(priority: .userInitiated) {
            await ServiceGraphFactory.build(userIdBox: userIdBox)
        }.value
    }

}

struct BootstrappedServices: @unchecked Sendable {

    let workerClient: WorkerClient

    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let readerSettingsStore: any ReaderSettingsStore

    let audioCoordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: any TTSPlaying
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPresenceController: TTSPresenceController
    let ttsPrewarmer: TTSPrewarmer

    let syncMetadataStore: any SyncMetadataStore
    let syncStatus: SyncStatus
    let syncEngine: SyncEngine
    let backgroundTaskCoordinator: BackgroundTaskCoordinator
    let apnsDeviceRegistrar: APNsDeviceRegistrar
    let chatRefreshAdapter: AppChatRefreshAdapter

    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let conversationLookup: ConversationLookup
    let chatService: RishiChatService

    let voicePresenter: VoiceSessionPresenter
    let voiceSessionRegistry: VoiceSessionRegistry

    let bookSearch: any BookSearch

    let indexingHook: any BookIndexingHook

    let billing: BillingRuntime

    let telemetryStore: any TelemetryStore

    let footerDetectionStore: any FooterDetectionStore
    let onboardingState: any OnboardingState
    let trialOnboardingState: any TrialOnboardingState
    let onboardingCoordinator: OnboardingCoordinator
    let readerDefaults: AppReaderDefaults
}

struct BillingRuntime: @unchecked Sendable {
    let entitlementService: EntitlementService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    let manageSubscriptionPresenter: ManageSubscriptionPresenter
    let entitlementReconciler: EntitlementReconciler
    let readerAppEntitlementFlag: ReaderAppEntitlementFlag
    let restoreService: RestoreService
    let workerReceiptVerifier: any ReceiptVerifier
    let groupID: Optional<GroupId>
}

@MainActor
final class UserIdBox {
    var value: UUID? = nil

    nonisolated init(
        _ value: UUID? = nil
    ) {
        
        self.value =  value
    }
    func setUserId(
        value: UUID
    ) {
        
        self.value =  value
    }
}

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
    static let defaultValue: AppDependencies? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}

private struct ServicesKey: EnvironmentKey {
    static let defaultValue: BootstrappedServices? = nil
}

extension EnvironmentValues {
    var services: BootstrappedServices? {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}

private struct CurrentUserKey: EnvironmentKey {
    static let defaultValue: User? = nil
}

extension EnvironmentValues {
    var currentUser: User? {
        get { self[CurrentUserKey.self] }
        set { self[CurrentUserKey.self] = newValue }
    }
}

private struct SignOutActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var signOut: () -> Void {
        get { self[SignOutActionKey.self] }
        set { self[SignOutActionKey.self] = newValue }
    }
}

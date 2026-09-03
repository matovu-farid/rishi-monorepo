import Foundation
import OSLog
import Observation















import SwiftUI

extension Notification.Name {
    static let rishiAccountDidChange = Notification.Name("rishi.account.didChange")
    static let rishiAccountTransitionStarted = Notification.Name("rishi.account.transitionStarted")
}

@MainActor
@Observable
final class AppDependencies {

    @MainActor static let shared = AppDependencies()

    private(set) var services: BootstrappedServices?
    nonisolated private static let accountGenerationKey = "rishi.account.generation"
    private(set) var accountGeneration: UInt64 =
        (UserDefaults.standard.object(forKey: "rishi.account.generation") as? NSNumber)?.uint64Value ?? 0

    private var bootstrapTask: Task<Void, Never>?
    private var identityRequestToken: UInt64 = 0
    var pendingAccountChange: AccountChangeTransaction?
    private var synchronousAccountTransitionFence: (@MainActor () -> Void)?
    private var carPlayAccountChangeObservers: [UUID: (CarPlayAccountSnapshot?) -> Void] = [:]

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    let macCommandRouter = MacCommandRouter()

    let macAccountMenu = MacAccountMenuModel()

    var cachedUserId: UUID? { userIdBox.value }

    public let userIdBox = UserIdBox()

    @ObservationIgnored
    private lazy var _backgroundSyncLifecycle = BackgroundSyncLifecycle(
        dependencies: self,
        userIdBox: self.userIdBox
    )

    var backgroundSyncLifecycle: BackgroundSyncLifecycle {
        _backgroundSyncLifecycle
    }

    nonisolated init() {}
    @discardableResult
    func replaceUserId(
        _ newValue: UUID?,
        allowDeferredCleanup: Bool = false,
        forceTransition: Bool = false,
        skipAccountFence: Bool = false
    ) async -> Bool {
        guard forceTransition || userIdBox.value != newValue else { return true }
        let transaction: AccountChangeTransaction?
        if skipAccountFence {
            transaction = nil
        } else {
            transaction = try? beginAccountChange()
            pendingAccountChange = nil
        }
        let requestToken = identityRequestToken
        await transaction?.drain.value

        guard let spotlight = services?.systemIntegration.spotlight else {
            guard identityRequestToken == requestToken else { return false }
            userIdBox.value = newValue
            notifyCarPlayAccountChange()
            return true
        }

        let result = await spotlight.transitionAccount {
            guard self.identityRequestToken == requestToken else { return false }
            if let newValue {
                guard (try? await RishiAppIntentRuntime.validatedPersistedIdentity()) == newValue,
                      self.identityRequestToken == requestToken else { return false }
            }
            self.userIdBox.value = newValue
            self.notifyCarPlayAccountChange()
            return true
        }
        return result.identityApplied
            && (result.cleanupComplete || allowDeferredCleanup)
    }

    /// Synchronizes the CarPlay scene with the persisted identity. CarPlay
    /// can connect while the phone app is still alive, so an identity change
    /// must tear down the shared reader before exposing the new account.
    @discardableResult
    func synchronizeCarPlayIdentity(_ userID: UUID?) async -> Bool {
        guard userIdBox.value != userID else { return true }
        return await replaceUserId(userID)
    }

    /// Invalidates identity work synchronously, then begins the owner drain.
    /// The returned transaction is safe to await from a later Task.
    func beginAccountChange() throws -> AccountChangeTransaction {
        synchronousAccountTransitionFence?()
        identityRequestToken &+= 1
        incrementAccountGeneration()
        let services = services
        let drain = Task { @MainActor in
            guard let services else { return }
            await services.audio.playbackOwner.stopForAccountChange()
        }
        let transaction = AccountChangeTransaction(
            expectedAccountGeneration: accountGeneration,
            drain: drain
        )
        pendingAccountChange = transaction
        return transaction
    }

    func installSynchronousAccountTransitionFence(
        _ fence: @escaping @MainActor () -> Void
    ) {
        synchronousAccountTransitionFence = fence
    }

    func invalidateIdentityRequests() {
        _ = try? beginAccountChange()
    }

    @discardableResult
    func addCarPlayAccountChangeObserver(
        _ observer: @escaping (CarPlayAccountSnapshot?) -> Void
    ) -> UUID {
        let token = UUID()
        carPlayAccountChangeObservers[token] = observer
        return token
    }

    func removeCarPlayAccountChangeObserver(_ token: UUID) {
        carPlayAccountChangeObservers.removeValue(forKey: token)
    }

    func notifyCarPlayAccountChange() {
        let snapshot = carPlayAccountSnapshot
        for observer in carPlayAccountChangeObservers.values {
            observer(snapshot)
        }
        NotificationCenter.default.post(
            name: .rishiAccountDidChange,
            object: self,
            userInfo: [
                "generation": NSNumber(value: accountGeneration),
                "hasAccount": NSNumber(value: userIdBox.value != nil)
            ]
        )
    }

    private func incrementAccountGeneration() {
        accountGeneration &+= 1
        UserDefaults.standard.set(accountGeneration, forKey: Self.accountGenerationKey)
        NotificationCenter.default.post(
            name: .rishiAccountTransitionStarted,
            object: self,
            userInfo: ["generation": NSNumber(value: accountGeneration)]
        )
    }

    var carPlayAccountSnapshot: CarPlayAccountSnapshot? {
        guard let userID = userIdBox.value else { return nil }
        return CarPlayAccountSnapshot(userID: userID, generation: accountGeneration)
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
            await built.voice.sessionRegistry.recoverPersistedSession()
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
    let sharedReadingAPI: SharedReadingAPI
    let dataUseConsentStore: any DataUseConsentStore

    let library: LibraryRuntime

    let audio: AudioRuntime

    let sync: SyncRuntime

    let chat: ChatRuntime

    let voice: VoiceRuntime

    let billing: BillingRuntime

    let settings: SettingsRuntime
    let onboarding: OnboardingRuntime
    let systemIntegration: SystemIntegrationRuntime
}

extension BootstrappedServices {
    func accountDeletionCoordinator(
        userId: UUID,
        signOut: @escaping @MainActor @Sendable () -> Void
    ) -> AccountDeletionCoordinator {
        AccountDeletionCoordinator(
            deleteServer: { [workerClient] in
                _ = try await workerClient.send(DeleteUserEndpoint())
            },
            purgeLocal: { [self] in
                var cleanupError: Error?
                await systemIntegration.spotlight.clearForAccountDeletion()
                await audio.playbackOwner.stopForAccountChange()
                await voice.presenter.requestEnd()
                await sync.engine.resetForAccountSwitch()
                do { try library.bookFileStorage.purgeAll() }
                catch { cleanupError = error }
                do { try await library.dbStore.purgeAll() }
                catch { cleanupError = cleanupError ?? error }
                if let metadataStore = sync.metadataStore as? SwiftDataSyncMetadataStore {
                    do { try await metadataStore.resetAll() }
                    catch { cleanupError = cleanupError ?? error }
                }
                await dataUseConsentStore.revoke(for: userId.uuidString)
                await audio.ttsSettingsStore.remove(userId: userId)
                await onboarding.trialState.remove(userId: userId)
                await billing.entitlementService.clearSnapshotCache(for: userId.uuidString)
                await billing.entitlementService.clearCache()
                await MainActor.run { billing.entitlementReconciler.reset() }
                if let cleanupError { throw cleanupError }
            },
            signOut: signOut,
            beginAccountChange: { try AppDependencies.shared.beginAccountChange() }
        )
    }
}

struct SettingsRuntime: @unchecked Sendable {
    let readerDefaults: AppReaderDefaults
    let telemetryStore: any TelemetryStore
    let footerDetectionStore: any FooterDetectionStore
}

struct OnboardingRuntime: @unchecked Sendable {
    let state: any OnboardingState
    let trialState: any TrialOnboardingState
    let coordinator: OnboardingCoordinator
}

struct VoiceRuntime: @unchecked Sendable {
    let presenter: VoiceSessionPresenter
    let sessionRegistry: VoiceSessionRegistry
}

struct AudioRuntime: @unchecked Sendable {
    let coordinator: AudioSessionCoordinator
    let ttsState: TTSPlaybackState
    let ttsEngine: any TTSPlaying
    let ttsSettingsStore: any TTSSettingsStore
    let nowPlayingController: NowPlayingController
    let ttsPresenceController: TTSPresenceController
    let ttsPrewarmer: TTSPrewarmer
    let playbackOwner: ReadAloudPlaybackOwner
}

struct ChatRuntime: @unchecked Sendable {
    let conversationStore: any ConversationStore
    let messageStore: any MessageStore
    let conversationLookup: ConversationLookup
    let service: RishiChatService
}

struct LibraryRuntime: @unchecked Sendable {
    let dbStore: RishiDBStore
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let readerSettingsStore: any ReaderSettingsStore
    let bookSearch: any BookSearch
    let indexingHook: any BookIndexingHook
    let sharePackageService: SharePackageService
    let sessionBookService: SessionBookService
}

struct SyncRuntime: @unchecked Sendable {
    let metadataStore: any SyncMetadataStore
    let status: SyncStatus
    let engine: SyncEngine
    let backgroundTaskCoordinator: BackgroundTaskCoordinator
    let chapterIndexGenerationDispatcher: ChapterIndexGenerationDispatcher
    let apnsDeviceRegistrar: APNsDeviceRegistrar
    let chatRefreshAdapter: AppChatRefreshAdapter
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

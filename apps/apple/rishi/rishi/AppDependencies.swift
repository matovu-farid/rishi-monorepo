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
    private(set) var activeAccountIdentity: LibraryAccountIdentity?

    private var bootstrapTask: Task<Void, Never>?
    private var launchEntitlementRefreshTask: Task<Result<EntitlementSnapshot, Error>?, Never>?
    private var identityRequestToken: UInt64 = 0
    var pendingAccountChange: AccountChangeTransaction?
    private var accountDeletionCleanupTransaction: AccountChangeTransaction?
    private var synchronousAccountTransitionFences: [UUID: @MainActor () -> Void] = [:]
    private var postSharedReadingDrainHandlers: [UUID: @MainActor (UUID) async -> Void] = [:]
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
        guard accountDeletionCleanupTransaction == nil else { return false }
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
            if let newValue, let library = services?.library {
                do {
                    try await library.bookMaterializationCoordinator.authorizeAccount(ownerID: newValue, generation: accountGeneration)
                } catch {
                    Log.error("library.import.account-authorization.failed", error: error)
                    return false
                }
                guard identityRequestToken == requestToken,
                      library.bookImportLifecycle.activateAccount(ownerID: newValue, generation: accountGeneration) else { return false }
            }
            userIdBox.value = newValue
            activeAccountIdentity = newValue.map { LibraryAccountIdentity(userID: $0, generation: accountGeneration) }
            notifyCarPlayAccountChange()
            return true
        }

        let result = await spotlight.transitionAccount {
            guard self.identityRequestToken == requestToken else { return false }
            if let newValue {
                guard (try? await RishiAppIntentRuntime.validatedPersistedIdentity()) == newValue,
                      self.identityRequestToken == requestToken else { return false }
                if let library = self.services?.library {
                    do {
                        try await library.bookMaterializationCoordinator.authorizeAccount(ownerID: newValue, generation: self.accountGeneration)
                    } catch {
                        Log.error("library.import.account-authorization.failed", error: error)
                        return false
                    }
                    guard self.identityRequestToken == requestToken,
                          library.bookImportLifecycle.activateAccount(ownerID: newValue, generation: self.accountGeneration) else { return false }
                }
            }
            self.userIdBox.value = newValue
            self.activeAccountIdentity = newValue.map { LibraryAccountIdentity(userID: $0, generation: self.accountGeneration) }
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
        guard accountDeletionCleanupTransaction == nil else {
            throw AccountDeletionCoordinatorError.accountChangedDuringDeletion
        }
        let outgoingAccount = userIdBox.value
        activeAccountIdentity = nil
        let outgoingGeneration = accountGeneration
        let outgoingAccountMutationPermit = outgoingAccount.map {
            AccountMutationPermit(ownerID: $0, accountGeneration: outgoingGeneration)
        }
        for fence in synchronousAccountTransitionFences.values { fence() }
        if let outgoingAccountMutationPermit {
            services?.library.scopedMutationStore.closeAdmission(for: outgoingAccountMutationPermit)
        }
        identityRequestToken &+= 1
        incrementAccountGeneration()
        let services = self.services
        let activationToken = outgoingAccount.map { ownerID in
            services?.library.bookImportLifecycle.activationToken(ownerID: ownerID, generation: accountGeneration)
                ?? BookImportActivationToken(ownerID: ownerID, generation: accountGeneration, transitionEpoch: 0)
        }
        let postSharedReadingDrainHandlers = self.postSharedReadingDrainHandlers
        let drain = Task { @MainActor in
            guard let services else { return }
            if let outgoingAccount {
                await services.sharedReadingSessionRegistry.drain(accountID: outgoingAccount)
                // The registry has completed local close and its bounded
                // remote leave window. Only now may UI routers release their
                // detached live contexts and memory-only invitations.
                for handler in postSharedReadingDrainHandlers.values {
                    await handler(outgoingAccount)
                }
            }
            await services.audio.playbackOwner.stopForAccountChange()
            if let outgoingAccountMutationPermit {
                try? await services.library.scopedMutationStore.revoke(outgoingAccountMutationPermit)
            }
            if let outgoingAccount {
                await services.library.bookImportLifecycle.drainAccount(outgoingAccount, generation: outgoingGeneration)
            }
        }
        let transaction = AccountChangeTransaction(
            expectedAccountGeneration: accountGeneration,
            outgoingAccountID: outgoingAccount,
            outgoingAccountGeneration: outgoingGeneration,
            activationToken: activationToken,
            outgoingAccountMutationPermit: outgoingAccountMutationPermit,
            drain: drain
        )
        pendingAccountChange = transaction
        return transaction
    }

    /// A failed server deletion leaves the local identity signed in. Reopen
    /// its active generation and discard only the completed transition token
    /// that deletion just drained.
    func restoreOwnerAfterDeletionFailure(_ token: BookImportActivationToken) async {
        guard userIdBox.value == token.ownerID, accountGeneration == token.generation else { return }
        if let mutations = services?.library.scopedMutationStore {
            do {
                try await mutations.activate(AccountMutationPermit(ownerID: token.ownerID, accountGeneration: token.generation))
            } catch {
                Log.error("account.mutation-authorization.restore.failed", error: error)
                return
            }
        }
        if let lifecycle = services?.library.bookImportLifecycle, !lifecycle.activateAccount(token) { return }
        activeAccountIdentity = LibraryAccountIdentity(userID: token.ownerID, generation: token.generation)
        if pendingAccountChange?.activationToken == token {
            pendingAccountChange = nil
        }
    }

    /// Reserves global account cleanup after the server deletion succeeds.
    /// Identity transitions stay closed while purge operations suspend.
    func beginAccountDeletionCleanup(_ transaction: AccountChangeTransaction) -> Bool {
        guard accountDeletionCleanupTransaction == nil,
              accountGeneration == transaction.expectedAccountGeneration,
              userIdBox.value == transaction.outgoingAccountID,
              pendingAccountChange === transaction else { return false }
        accountDeletionCleanupTransaction = transaction
        return true
    }

    /// Called synchronously immediately before the sign-out action. Both run
    /// on MainActor, so no other transition can interleave between release and
    /// the sign-out closure's start.
    func endAccountDeletionCleanup(_ transaction: AccountChangeTransaction) {
        guard accountDeletionCleanupTransaction === transaction else { return }
        accountDeletionCleanupTransaction = nil
    }

    @discardableResult
    func installSynchronousAccountTransitionFence(
        _ fence: @escaping @MainActor () -> Void
    ) -> UUID {
        let token = UUID()
        synchronousAccountTransitionFences[token] = fence
        return token
    }

    func removeSynchronousAccountTransitionFence(_ token: UUID) {
        synchronousAccountTransitionFences.removeValue(forKey: token)
    }

    /// Registers account-scoped UI cleanup that must happen after, never
    /// before, the shared-reading registry's two-phase drain.
    @discardableResult
    func installPostSharedReadingDrainHandler(
        _ handler: @escaping @MainActor (UUID) async -> Void
    ) -> UUID {
        let token = UUID()
        postSharedReadingDrainHandlers[token] = handler
        return token
    }

    func removePostSharedReadingDrainHandler(_ token: UUID) {
        postSharedReadingDrainHandlers.removeValue(forKey: token)
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
            if self.pendingAccountChange == nil, let userID = self.userIdBox.value {
                self.activeAccountIdentity = LibraryAccountIdentity(userID: userID, generation: self.accountGeneration)
            }
            _ = self.installSynchronousAccountTransitionFence { [weak self, lifecycle = built.library.bookImportLifecycle] in
                guard let self, let ownerID = self.userIdBox.value else { return }
                lifecycle.fenceAccount(ownerID: ownerID, generation: self.accountGeneration)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["RISHI_UITEST"] == "1",
               let userID = self.userIdBox.value {
                await built.onboarding.state.setHasCompletedOnboarding(true)
                await built.dataUseConsentStore.grant(for: userID.uuidString)
            }
            #endif
            await built.voice.sessionRegistry.recoverPersistedSession()
            Self.signposter.endInterval("cold-launch.bootstrap", state)
        }
        bootstrapTask = task
        await task.value
    }

    func refreshEntitlementsAtLaunch() async {
        guard let coordinator = services?.billing.entitlementRefreshCoordinator else { return }
        if let launchEntitlementRefreshTask {
            await launchEntitlementRefreshTask.value
            return
        }

        let task = Task {
            await coordinator.refreshIfSignedIn(reason: .launch)
        }
        launchEntitlementRefreshTask = task
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
    let sharedReadingSessionRegistry: SharedReadingSessionRegistry
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
                let generation = (UserDefaults.standard.object(forKey: "rishi.account.generation") as? NSNumber)?.uint64Value ?? 0
                try await purgeAccountLocally(userID: userId, outgoingGeneration: generation)
            },
            purgeLocalForGeneration: { [self] generation in try await purgeAccountLocally(userID: userId, outgoingGeneration: generation) },
            currentAccountGeneration: {
                (UserDefaults.standard.object(forKey: "rishi.account.generation") as? NSNumber)?.uint64Value ?? 0
            },
            reactivateLocalOwner: { token in await AppDependencies.shared.restoreOwnerAfterDeletionFailure(token) },
            beginAccountDeletionCleanup: { AppDependencies.shared.beginAccountDeletionCleanup($0) },
            endAccountDeletionCleanup: { AppDependencies.shared.endAccountDeletionCleanup($0) },
            signOut: signOut,
            beginAccountChange: { try AppDependencies.shared.beginAccountChange() }
        )
    }

    private func purgeAccountLocally(userID: UUID, outgoingGeneration: UInt64) async throws -> BookImportActivationToken {
        var cleanupError: Error?
        let activationToken = library.bookImportLifecycle.fenceAccount(ownerID: userID, generation: outgoingGeneration)
        let accountMutationPermit = AccountMutationPermit(ownerID: userID, accountGeneration: outgoingGeneration)
        library.scopedMutationStore.closeAdmission(for: accountMutationPermit)
        await systemIntegration.spotlight.clearForAccountDeletion()
        await audio.playbackOwner.stopForAccountChange()
        await voice.presenter.requestEnd()
        await sharedReadingSessionRegistry.drain(accountID: userID)
        await sync.engine.resetForAccountSwitch()
        do { try await library.scopedMutationStore.revoke(accountMutationPermit) }
        catch { cleanupError = error }
        await library.bookImportLifecycle.drainAccount(userID, generation: outgoingGeneration)
        do { try library.bookFileStorage.purgeAll() }
        catch { cleanupError = error }
        do { try await library.dbStore.purgeAll() }
        catch { cleanupError = cleanupError ?? error }
        if let metadataStore = sync.metadataStore as? SwiftDataSyncMetadataStore {
            do { try await metadataStore.resetAll() }
            catch { cleanupError = cleanupError ?? error }
        }
        await dataUseConsentStore.revoke(for: userID.uuidString)
        await audio.ttsSettingsStore.remove(userId: userID)
        await onboarding.trialState.remove(userId: userID)
        await billing.entitlementService.clearSnapshotCache(for: userID.uuidString)
        await billing.entitlementService.clearCache()
        await MainActor.run { billing.entitlementReconciler.reset() }
        if let cleanupError { throw cleanupError }
        return activationToken
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
    let scopedMutationStore: BookScopedMutationStore
    let bookStore: any BookStore
    let positionStore: any PositionStore
    let highlightStore: any HighlightStore
    let bookmarkStore: any BookmarkStore
    let bookFileStorage: BookFileStorage
    let importCoordinator: ImportCoordinator
    let sampleBookInstaller: SampleBookInstaller
    let sampleReaderInstaller: SampleReaderInstaller
    let readerSettingsStore: any ReaderSettingsStore
    let chapterIndexPersistence: any ChapterIndexPersistence
    let chapterSummarizer: ChapterSummarizer
    let epubUnpackedCache: EPUBUnpackedCache
    let bookSearch: any BookSearch
    let indexingHook: any BookIndexingHook
    let sharePackageService: SharePackageService
    let sessionBookService: SessionBookService
    let bookSourceRegistry: BookSourceRegistry
    let bookImportLifecycle: BookImportLifecycle
    let bookMaterializationCoordinator: BookMaterializationCoordinator
    let bookImportEvents: BookImportEvents
    let currentAccountGeneration: @Sendable () async -> UInt64?
    let bookImportRecovery: BookImportRecovery
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

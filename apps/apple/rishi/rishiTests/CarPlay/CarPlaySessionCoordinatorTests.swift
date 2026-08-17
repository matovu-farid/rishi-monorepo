#if os(iOS) && canImport(CarPlay)
import CarPlay
import Testing
@testable import rishi

@Suite("CarPlay session state")
@MainActor
struct CarPlaySessionCoordinatorTests {
    @Test("CarPlay scene configuration uses the CarPlay role")
    func carPlayRoleConstantIsAvailable() {
        #expect(UISceneSession.Role.carTemplateApplication.rawValue.isEmpty == false)
        #expect(CarPlaySceneDelegate.self is any CPTemplateApplicationSceneDelegate.Type)

        final class Marker: NSObject {}
        let current = Marker()
        let stale = Marker()
        #expect(CarPlaySceneDelegate.isCurrentInterfaceController(
            connected: ObjectIdentifier(current),
            callback: ObjectIdentifier(current)
        ))
        #expect(!CarPlaySceneDelegate.isCurrentInterfaceController(
            connected: ObjectIdentifier(current),
            callback: ObjectIdentifier(stale)
        ))
    }

    @Test("catalog rows become invalid when the account generation changes")
    func catalogRowsAreBoundToAccount() {
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let otherUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let catalogAccount = CarPlayAccountSnapshot(userID: userID, generation: 3)

        #expect(CarPlaySessionCoordinator.isCatalogCurrent(catalogAccount, current: catalogAccount))
        #expect(!CarPlaySessionCoordinator.isCatalogCurrent(
            catalogAccount,
            current: CarPlayAccountSnapshot(userID: userID, generation: 4)
        ))
        #expect(!CarPlaySessionCoordinator.isCatalogCurrent(
            catalogAccount,
            current: CarPlayAccountSnapshot(userID: otherUserID, generation: 3)
        ))
        #expect(!CarPlaySessionCoordinator.isCatalogCurrent(catalogAccount, current: nil))
    }

    @Test("CarPlay identity synchronization clears a stale account")
    func identitySynchronizationClearsStaleAccount() async {
        let dependencies = AppDependencies()
        await dependencies.replaceUserId(UUID(uuidString: "00000000-0000-0000-0000-000000000023")!)
        let generation = dependencies.accountGeneration

        await dependencies.synchronizeCarPlayIdentity(nil)

        #expect(dependencies.carPlayAccountSnapshot == nil)
        #expect(dependencies.accountGeneration == generation + 1)
    }

    @Test("account observers receive sign-in and sign-out transitions")
    func accountObserversReceiveTransitions() async {
        let dependencies = AppDependencies()
        var observed: [CarPlayAccountSnapshot?] = []
        let token = dependencies.addCarPlayAccountChangeObserver { snapshot in
            observed.append(snapshot)
        }
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!

        await dependencies.replaceUserId(userID)
        await dependencies.replaceUserId(nil)

        #expect(observed.count == 2)
        #expect(observed[0]?.userID == userID)
        #expect(observed.last == nil)

        dependencies.removeCarPlayAccountChangeObserver(token)
        await dependencies.replaceUserId(userID)
        #expect(observed.count == 2)
    }

    @Test("releasing a CarPlay host detaches without stopping shared playback")
    func releasingHostPreservesSharedController() async {
        let state = TTSPlaybackState()
        let owner = ReadAloudPlaybackOwner(
            ttsEngine: FakeTTSEngine(state: state, script: .holds),
            ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: ControllerNoopChunkSource()),
            ttsPresence: TTSPresenceController(
                state: state,
                store: ControllerNoopPresenceStore()
            ),
            coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
            nowPlayingController: NowPlayingController(
                infoSurface: FakeNowPlayingInfoSurface(),
                commandSurface: FakeRemoteCommandSurface()
            )
        )
        let controller = owner.makeController(userId: UUID(), bookFileStorage: nil)
        let host = UUID()

        await owner.install(controller: controller, host: host)
        await owner.release(host: host)

        #expect(owner.activeController === controller)
        #expect(owner.activeHost == nil)
        controller.dispose()
    }
}
#endif

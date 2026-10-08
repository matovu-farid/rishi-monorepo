#if os(iOS) && canImport(CarPlay)
import CarPlay
import Testing
@testable import rishi

private struct CarPlayNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class CarPlayNoopPresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
}

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
    func identitySynchronizationClearsStaleAccount() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        let session = try installStagingCredentials("00000000-0000-0000-0000-000000000023", authority: authority)
        try await dependencies.restoreCredentialIdentity(session)
        let generation = dependencies.accountGeneration

        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let cleanup = try #require(dependencies.retireCredentialAccount(transaction))
        await cleanup.value

        #expect(dependencies.carPlayAccountSnapshot == nil)
        #expect(dependencies.accountGeneration == generation + 1)
    }

    @Test("account observers receive sign-in and sign-out transitions")
    func accountObserversReceiveTransitions() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let fixture = try CredentialIdentityFixture(authority: authority)
        let dependencies = fixture.dependencies
        var observed: [CarPlayAccountSnapshot?] = []
        let token = dependencies.addCarPlayAccountChangeObserver { snapshot in
            observed.append(snapshot)
        }
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!

        let installation = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        _ = try await dependencies.installCredentialSession(Session(token: "fixture", userId: userID.uuidString, email: nil), refreshToken: nil, in: installation)
        let retirement = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let cleanup = try #require(dependencies.retireCredentialAccount(retirement))
        await cleanup.value

        #expect(observed.count == 2)
        #expect(observed[0]?.userID == userID)
        #expect(observed[1] == nil)

        dependencies.removeCarPlayAccountChangeObserver(token)
        let replacement = try dependencies.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        _ = try await dependencies.installCredentialSession(Session(token: "replacement", userId: userID.uuidString, email: nil), refreshToken: nil, in: replacement)
        #expect(observed.count == 2)
    }

    @Test("releasing a CarPlay host detaches without stopping shared playback")
    func releasingHostPreservesSharedController() async {
        let state = TTSPlaybackState()
        let owner = ReadAloudPlaybackOwner(
            ttsEngine: FakeTTSEngine(state: state, script: .holds),
            ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: CarPlayNoopChunkSource()),
            ttsPresence: TTSPresenceController(
                state: state,
                store: CarPlayNoopPresenceStore()
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

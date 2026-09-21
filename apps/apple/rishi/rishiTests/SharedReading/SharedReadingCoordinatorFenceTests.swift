import Foundation
import Testing

@testable import rishi

@Suite("Shared reading coordinator authority fences")
struct SharedReadingCoordinatorFenceTests {
    @Test("a newer room epoch clears subordinate fences before accepting its roster")
    func newerEpochResetsSubordinateFences() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 1, connectionGeneration: 4), bearerToken: "bearer")

        transport.yield(.participantRoster(roster(roomEpoch: 1, rosterGeneration: 9, controllerGeneration: 7, connectionGeneration: 4, controller: "old")))
        await Task.yield()
        transport.yield(.participantRoster(roster(roomEpoch: 2, rosterGeneration: 1, controllerGeneration: 1, connectionGeneration: 1, controller: "new")))
        await Task.yield()

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.roomEpoch == 2)
        #expect(snapshot.rosterGeneration == 1)
        #expect(snapshot.controllerGeneration == 1)
        #expect(snapshot.connectionGeneration == 1)
        #expect(snapshot.currentParticipantUserId == "new")
    }

    @Test("stale roster generation cannot overwrite an authoritative roster")
    func staleRosterDoesNotOverwriteCurrentRoster() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 1, connectionGeneration: 1), bearerToken: "bearer")

        transport.yield(.participantRoster(roster(roomEpoch: 1, rosterGeneration: 2, controllerGeneration: 1, connectionGeneration: 1, controller: "current")))
        await Task.yield()
        transport.yield(.participantRoster(roster(roomEpoch: 1, rosterGeneration: 1, controllerGeneration: 1, connectionGeneration: 1, controller: "stale")))
        await Task.yield()

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.currentParticipantUserId == "current")
        #expect(snapshot.rosterGeneration == 2)
    }

    @Test("an invalid newer epoch leaves every authoritative field unchanged")
    func invalidNewerEpochDoesNotMutateState() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 1, connectionGeneration: 1), bearerToken: "bearer")
        transport.yield(.participantRoster(roster(roomEpoch: 1, rosterGeneration: 2, controllerGeneration: 3, connectionGeneration: 4, controller: "current")))
        await Task.yield()
        let before = await coordinator.snapshot()

        transport.yield(.participantRoster(roster(roomEpoch: 2, rosterGeneration: 1, controllerGeneration: .init(rawValue: -1), connectionGeneration: 1, controller: "invalid")))
        await Task.yield()

        #expect(await coordinator.snapshot() == before)
    }

    @Test("a stale terminal state cannot finish a current session")
    func staleTerminalStateIsIgnored() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 2, connectionGeneration: 2), bearerToken: "bearer")

        transport.yield(.sessionState(.init(sessionId: "session", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 1, status: .ended, controllerUserId: "old")))
        await Task.yield()

        #expect((await coordinator.snapshot()).status == .waiting)
        #expect(transport.authoritativeStateConfirmations == 0)
    }

    @Test("only an accepted session state confirms reconnect authority")
    func acceptedSessionStateConfirmsReconnectAuthority() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 2, connectionGeneration: 2), bearerToken: "bearer")

        transport.yield(.sessionState(.init(sessionId: "session", roomEpoch: 2, controllerGeneration: 1, connectionGeneration: 2, status: .waiting, controllerUserId: "local")))
        await Task.yield()

        #expect(transport.authoritativeStateConfirmations == 1)
    }

    @Test("roster and controller progress accept lower source connection generations")
    func lowerSourceConnectionGenerationDoesNotRejectRoomAuthority() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 1, connectionGeneration: 5), bearerToken: "bearer")

        transport.yield(.participantRoster(roster(roomEpoch: 1, rosterGeneration: 1, controllerGeneration: 1, connectionGeneration: 0, controller: "remote")))
        await Task.yield()
        transport.yield(.syncFrame(.init(sessionId: "session", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 0, sequence: 1, bookId: "book", contentHash: "hash", format: .epub, position: "position", isPlaying: false, ttsRate: 1)))
        await Task.yield()

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.currentParticipantUserId == "remote")
        #expect(snapshot.latestProgress?.sequence == 1)
        #expect(snapshot.connectionGeneration == 5)
    }

    @Test("remote connection generations never alter a local action fence")
    func remoteConnectionGenerationDoesNotReplaceLocalFence() async throws {
        let transport = SharedReadingTestTransport()
        let coordinator = SharedReadingSessionCoordinator(transport: transport, localParticipantUserId: "local")
        try await coordinator.connect(admission: admission(roomEpoch: 1, connectionGeneration: 1), bearerToken: "bearer")

        transport.yield(.syncFrame(.init(sessionId: "session", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 2, sequence: 1, bookId: "book", contentHash: "hash", format: .epub, position: "position", isPlaying: false, ttsRate: 1)))
        await Task.yield()
        try await coordinator.requestSpeaker()

        guard case .speakerRequest(let fence, _) = transport.sentMessages.last else {
            Issue.record("expected a speaker request")
            return
        }
        #expect(fence.connectionGeneration == 1)
    }

    private func admission(roomEpoch: SharedReadingRoomEpoch, connectionGeneration: SharedReadingConnectionGeneration) -> SharedReadingAdmission {
        SharedReadingAdmission(admissionTicket: "ticket", websocketURL: URL(string: "wss://sharing.rishi.test")!, roomEpoch: roomEpoch, connectionGeneration: connectionGeneration, status: .waiting)
    }

    private func roster(
        roomEpoch: SharedReadingRoomEpoch,
        rosterGeneration: SharedReadingRosterGeneration,
        controllerGeneration: SharedReadingControllerGeneration,
        connectionGeneration: SharedReadingConnectionGeneration,
        controller: String
    ) -> SharedReadingParticipantRosterEvent {
        SharedReadingParticipantRosterEvent(
            sessionId: "session",
            roomEpoch: roomEpoch,
            controllerGeneration: controllerGeneration,
            connectionGeneration: connectionGeneration,
            rosterGeneration: rosterGeneration,
            participants: [.init(userId: controller, displayName: controller, avatarURL: nil, joinedAt: .now, bookReady: true, connectionState: "connected", isController: true)]
        )
    }
}

private final class SharedReadingTestTransport: SharedReadingSignalingTransport, @unchecked Sendable {
    private let stream: AsyncStream<SharedReadingSignalingEvent>
    private let continuation: AsyncStream<SharedReadingSignalingEvent>.Continuation
    private(set) var authoritativeStateConfirmations = 0
    private(set) var sentMessages: [SharedReadingSignalingOutgoingMessage] = []

    init() {
        var continuation: AsyncStream<SharedReadingSignalingEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var events: AsyncStream<SharedReadingSignalingEvent> { stream }

    func connect(admission: SharedReadingAdmission, bearerToken: String, refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?, refreshBearerToken: (@Sendable () async throws -> String)?) async throws {}
    func disconnect() async {}
    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws { sentMessages.append(message) }
    func confirmAuthoritativeSessionState(_ state: SharedReadingSessionStateEvent) async { authoritativeStateConfirmations += 1 }
    func yield(_ event: SharedReadingSignalingEvent) { continuation.yield(event) }
}

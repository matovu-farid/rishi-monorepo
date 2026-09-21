import Foundation

struct SharedReadingSessionCoordinatorSnapshot: Sendable, Equatable {
    let sessionId: String?
    let status: SharedReadingSessionStatus
    let roomEpoch: SharedReadingRoomEpoch
    let rosterGeneration: SharedReadingRosterGeneration
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let currentParticipantUserId: String?
    let participants: [SharedReadingParticipant]
    let speakerUserId: String?
    let lastAcceptedSyncSequence: Int64
    let lastSentSyncSequence: Int64
    let latestProgress: SharedReadingProgress?
}

actor SharedReadingSessionCoordinator {
    nonisolated let stateUpdates: AsyncStream<SharedReadingSessionCoordinatorSnapshot>
    private let stateContinuation: AsyncStream<SharedReadingSessionCoordinatorSnapshot>.Continuation

    private let transport: any SharedReadingSignalingTransport
    private let localParticipantUserId: String
    private let refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?
    private let refreshBearerToken: (@Sendable () async throws -> String)?

    private var eventTask: Task<Void, Never>?
    private var didFinish = false
    private var sessionId: String?
    private(set) var status: SharedReadingSessionStatus = .waiting
    private(set) var roomEpoch: SharedReadingRoomEpoch = 0
    private(set) var rosterGeneration: SharedReadingRosterGeneration = 0
    private(set) var controllerGeneration: SharedReadingControllerGeneration = 0
    private(set) var connectionGeneration: SharedReadingConnectionGeneration = 0
    private(set) var currentParticipantUserId: String?
    private(set) var participants: [SharedReadingParticipant] = []
    private(set) var speakerUserId: String?
    private(set) var lastAcceptedSyncSequence: Int64 = -1
    private(set) var lastSentSyncSequence: Int64 = -1
    private(set) var latestProgress: SharedReadingProgress?

    init(
        transport: any SharedReadingSignalingTransport,
        localParticipantUserId: String,
        refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)? = nil,
        refreshBearerToken: (@Sendable () async throws -> String)? = nil
    ) {
        self.transport = transport
        self.localParticipantUserId = localParticipantUserId
        self.refreshAdmission = refreshAdmission
        self.refreshBearerToken = refreshBearerToken

        var continuation: AsyncStream<SharedReadingSessionCoordinatorSnapshot>.Continuation!
        self.stateUpdates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    func connect(admission: SharedReadingAdmission, bearerToken: String) async throws {
        guard !didFinish else {
            throw SharedReadingError.from(code: .sessionEnded)
        }
        guard admission.status != .ended else {
            throw SharedReadingError.from(code: .sessionEnded)
        }

        sessionId = nil
        roomEpoch = admission.roomEpoch
        rosterGeneration = 0
        connectionGeneration = admission.connectionGeneration
        controllerGeneration = 0
        status = admission.status
        currentParticipantUserId = nil
        participants = []
        speakerUserId = nil
        lastAcceptedSyncSequence = -1
        lastSentSyncSequence = -1
        latestProgress = nil
        publishSnapshot()

        let transport = self.transport
        let refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)? = self.refreshAdmission.map { refresh in
            { @Sendable [weak self] in
                let admission = try await refresh()
                await self?.applyLocalAdmission(admission)
                return admission
            }
        }
        eventTask?.cancel()
        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self else { return }
                await self.handle(event)
            }
        }

        do {
            try await transport.connect(
                admission: admission,
                bearerToken: bearerToken,
                refreshAdmission: refreshAdmission,
                refreshBearerToken: refreshBearerToken
            )
        } catch {
            eventTask?.cancel()
            eventTask = nil
            throw error
        }
    }

    func start() async throws {
        try ensureNotEnded()
        guard status != .active else { return }
        guard isLocalController else {
            throw SharedReadingError.from(code: .waitingForController)
        }

        try await transport.send(.sessionStart(currentFence()))
        status = .active
        publishSnapshot()
    }

    func leave() async {
        if didFinish {
            return
        }
        if !isLocalController {
            // Leaving is caller-initiated and should still work even if the
            // controller role already moved elsewhere.
        }
        try? await transport.send(.leave(currentFence()))
        await finishLocally(disconnectTransport: true)
    }

    /// Used by the app-lifetime registry while an account is transitioning.
    /// The registry sends the best-effort HTTP leave separately after this has
    /// stopped every local signaling task.
    func cancelLocally() async {
        await finishLocally(disconnectTransport: true)
    }

    func end() async throws {
        try ensureNotEnded()
        guard isLocalController else {
            throw SharedReadingError.from(code: .waitingForController)
        }

        try await transport.send(.end(currentFence()))
        await finishLocally(disconnectTransport: true)
    }

    func snapshot() -> SharedReadingSessionCoordinatorSnapshot {
        SharedReadingSessionCoordinatorSnapshot(
            sessionId: sessionId,
            status: status,
            roomEpoch: roomEpoch,
            rosterGeneration: rosterGeneration,
            controllerGeneration: controllerGeneration,
            connectionGeneration: connectionGeneration,
            currentParticipantUserId: currentParticipantUserId,
            participants: participants,
            speakerUserId: speakerUserId,
            lastAcceptedSyncSequence: lastAcceptedSyncSequence,
            lastSentSyncSequence: lastSentSyncSequence,
            latestProgress: latestProgress
        )
    }

    func requestSpeaker() async throws {
        try ensureNotEnded()
        try await transport.send(.speakerRequest(currentFence(), requestId: UUID().uuidString))
    }

    func releaseSpeaker() async throws {
        try ensureNotEnded()
        try await transport.send(.speakerRelease(currentFence()))
    }

    func sendControllerSyncFrame(_ progress: SharedReadingProgress) async throws {
        try ensureNotEnded()
        guard status == .active else {
            throw SharedReadingError.from(code: .waitingForController)
        }
        guard isLocalController else {
            throw SharedReadingError.from(code: .waitingForController)
        }
        guard progress.sequence > lastSentSyncSequence else {
            return
        }
        if let sessionId, sessionId != progress.sessionId {
            return
        }

        let frame = SharedReadingSyncFrame(
            sessionId: sessionId ?? progress.sessionId,
            roomEpoch: roomEpoch,
            controllerGeneration: controllerGeneration,
            connectionGeneration: connectionGeneration,
            sequence: progress.sequence,
            bookId: progress.bookId,
            contentHash: progress.contentHash,
            format: progress.format,
            position: progress.position,
            isPlaying: progress.isPlaying,
            ttsRate: progress.ttsRate
        )

        try await transport.send(.syncFrame(frame))
        lastSentSyncSequence = progress.sequence
        publishSnapshot()
    }

    private var isLocalController: Bool {
        currentParticipantUserId == localParticipantUserId
    }

    private func ensureNotEnded() throws {
        guard !didFinish, status != .ended else {
            throw SharedReadingError.from(code: .sessionEnded)
        }
    }

    private func currentFence() -> SharedReadingSignalFence {
        SharedReadingSignalFence(
            roomEpoch: roomEpoch,
            controllerGeneration: controllerGeneration,
            connectionGeneration: connectionGeneration
        )
    }

    private func applyLocalAdmission(_ admission: SharedReadingAdmission) {
        guard !didFinish, admission.status != .ended else { return }
        if admission.roomEpoch > roomEpoch {
            roomEpoch = admission.roomEpoch
            rosterGeneration = 0
            controllerGeneration = 0
            currentParticipantUserId = nil
            participants = []
            speakerUserId = nil
            lastAcceptedSyncSequence = -1
            lastSentSyncSequence = -1
            latestProgress = nil
        }
        connectionGeneration = admission.connectionGeneration
        publishSnapshot()
    }

    private func handle(_ event: SharedReadingSignalingEvent) async {
        guard !didFinish else { return }

        switch event {
        case .sessionState(let state):
            await applySessionState(state)
        case .syncFrame(let frame):
            guard acceptsAuthority(
                sessionId: frame.sessionId,
                roomEpoch: frame.roomEpoch,
                controllerGeneration: frame.controllerGeneration,
                connectionGeneration: frame.connectionGeneration
            ), frame.sequence > lastAcceptedSyncSequence else { return }
            lastAcceptedSyncSequence = frame.sequence
            latestProgress = SharedReadingProgress(
                sessionId: frame.sessionId ?? sessionId ?? "",
                bookId: frame.bookId,
                contentHash: frame.contentHash,
                format: frame.format,
                sequence: frame.sequence,
                position: frame.position,
                isPlaying: frame.isPlaying,
                ttsRate: frame.ttsRate,
                updatedAt: Date()
            )
            publishSnapshot()
        case .controllerTransfer(let transfer):
            guard acceptsAuthority(
                sessionId: transfer.sessionId,
                roomEpoch: transfer.roomEpoch,
                controllerGeneration: transfer.controllerGeneration,
                connectionGeneration: transfer.connectionGeneration
            ) else { return }
            currentParticipantUserId = transfer.toUserId
            lastAcceptedSyncSequence = -1
            latestProgress = nil
            publishSnapshot()
        case .participantRemove(let removal):
            guard acceptsAuthority(
                sessionId: removal.sessionId,
                roomEpoch: removal.roomEpoch,
                controllerGeneration: removal.controllerGeneration,
                connectionGeneration: removal.connectionGeneration
            ) else { return }
            if currentParticipantUserId == removal.userId {
                currentParticipantUserId = nil
            }
            if speakerUserId == removal.userId {
                speakerUserId = nil
            }
            publishSnapshot()
            if removal.userId == localParticipantUserId {
                await finishLocally(disconnectTransport: true)
            }
        case .participantRoster(let roster):
            guard acceptsAuthority(
                sessionId: roster.sessionId,
                roomEpoch: roster.roomEpoch,
                rosterGeneration: roster.rosterGeneration,
                controllerGeneration: roster.controllerGeneration,
                connectionGeneration: roster.connectionGeneration
            ) else { return }
            participants = roster.participants
            currentParticipantUserId = roster.participants.first(where: { $0.isController })?.userId ?? currentParticipantUserId
            publishSnapshot()
        case .speakerGranted(let granted):
            guard acceptsAuthority(
                sessionId: granted.sessionId,
                roomEpoch: granted.roomEpoch,
                controllerGeneration: granted.controllerGeneration,
                connectionGeneration: granted.connectionGeneration
            ) else { return }
            speakerUserId = granted.speakerUserId
            publishSnapshot()
        case .speakerReleased(let released):
            guard acceptsAuthority(
                sessionId: released.sessionId,
                roomEpoch: released.roomEpoch,
                controllerGeneration: released.controllerGeneration,
                connectionGeneration: released.connectionGeneration
            ) else { return }
            if speakerUserId == released.speakerUserId {
                speakerUserId = nil
            }
            publishSnapshot()
        case .sessionEnded(let ended):
            guard acceptsAuthority(
                sessionId: ended.sessionId,
                roomEpoch: ended.roomEpoch,
                controllerGeneration: ended.controllerGeneration,
                connectionGeneration: ended.connectionGeneration
            ) else { return }
            await finishLocally(disconnectTransport: true)
        case .sdpOffer, .sdpAnswer, .ice:
            // Peer media transport consumes these events; the room coordinator
            // only owns lifecycle/control and authoritative reader state.
            return
        case .error(let error):
            if error.code == .sessionEnded || error.code == .removedFromSession {
                await finishLocally(disconnectTransport: false)
            }
        }
    }

    private func applySessionState(_ state: SharedReadingSessionStateEvent) async {
        guard acceptsAuthority(
            sessionId: state.sessionId,
            roomEpoch: state.roomEpoch,
            controllerGeneration: state.controllerGeneration,
            connectionGeneration: state.connectionGeneration
        ) else { return }
        status = state.status
        currentParticipantUserId = state.controllerUserId
        lastAcceptedSyncSequence = -1
        lastSentSyncSequence = -1
        latestProgress = nil
        participants = []
        publishSnapshot()

        if state.status == .ended {
            await finishLocally(disconnectTransport: true)
        } else {
            await transport.confirmAuthoritativeSessionState(state)
        }
    }

    private func acceptsAuthority(
        sessionId incomingSessionId: String?,
        roomEpoch incomingRoomEpoch: SharedReadingRoomEpoch,
        rosterGeneration incomingRosterGeneration: SharedReadingRosterGeneration? = nil,
        controllerGeneration incomingControllerGeneration: SharedReadingControllerGeneration,
        connectionGeneration incomingConnectionGeneration: SharedReadingConnectionGeneration
    ) -> Bool {
        guard incomingRoomEpoch.rawValue >= 0,
              incomingControllerGeneration.rawValue >= 0,
              incomingConnectionGeneration.rawValue >= 0,
              incomingRosterGeneration.map({ $0.rawValue >= 0 }) ?? true,
              incomingSessionId == nil || sessionId == nil || incomingSessionId == sessionId,
              incomingRoomEpoch >= roomEpoch else { return false }

        if incomingRoomEpoch > roomEpoch {
            roomEpoch = incomingRoomEpoch
            rosterGeneration = 0
            controllerGeneration = 0
            currentParticipantUserId = nil
            participants = []
            speakerUserId = nil
            lastAcceptedSyncSequence = -1
            lastSentSyncSequence = -1
            latestProgress = nil
        }

        guard incomingControllerGeneration >= controllerGeneration,
              incomingRosterGeneration.map({ $0 >= rosterGeneration }) ?? true else { return false }

        sessionId = incomingSessionId ?? sessionId
        controllerGeneration = max(controllerGeneration, incomingControllerGeneration)
        if let incomingRosterGeneration {
            rosterGeneration = max(rosterGeneration, incomingRosterGeneration)
        }
        return true
    }

    private func finishLocally(disconnectTransport: Bool) async {
        guard !didFinish else { return }
        didFinish = true
        status = .ended
        currentParticipantUserId = nil
        participants = []
        speakerUserId = nil
        lastAcceptedSyncSequence = -1
        lastSentSyncSequence = -1
        publishSnapshot()

        eventTask?.cancel()
        eventTask = nil

        if disconnectTransport {
            await transport.disconnect()
        }

        stateContinuation.finish()
    }

    private func publishSnapshot() {
        stateContinuation.yield(
            SharedReadingSessionCoordinatorSnapshot(
                sessionId: sessionId,
                status: status,
                roomEpoch: roomEpoch,
                rosterGeneration: rosterGeneration,
                controllerGeneration: controllerGeneration,
                connectionGeneration: connectionGeneration,
                currentParticipantUserId: currentParticipantUserId,
                participants: participants,
                speakerUserId: speakerUserId,
                lastAcceptedSyncSequence: lastAcceptedSyncSequence,
                lastSentSyncSequence: lastSentSyncSequence,
                latestProgress: latestProgress
            )
        )
    }
}

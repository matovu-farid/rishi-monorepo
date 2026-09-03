import Foundation

struct SharedReadingSessionCoordinatorSnapshot: Sendable, Equatable {
    let sessionId: String?
    let status: SharedReadingSessionStatus
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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

    private var eventTask: Task<Void, Never>?
    private var didFinish = false
    private var sessionId: String?
    private(set) var status: SharedReadingSessionStatus = .waiting
    private(set) var roomEpoch: Int = 0
    private(set) var controllerGeneration: Int = 0
    private(set) var connectionGeneration: Int = 0
    private(set) var currentParticipantUserId: String?
    private(set) var participants: [SharedReadingParticipant] = []
    private(set) var speakerUserId: String?
    private(set) var lastAcceptedSyncSequence: Int64 = -1
    private(set) var lastSentSyncSequence: Int64 = -1
    private(set) var latestProgress: SharedReadingProgress?

    init(
        transport: any SharedReadingSignalingTransport,
        localParticipantUserId: String,
        refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)? = nil
    ) {
        self.transport = transport
        self.localParticipantUserId = localParticipantUserId
        self.refreshAdmission = refreshAdmission

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
        eventTask?.cancel()
        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self else { return }
                await self.handle(event)
            }
        }

        do {
            try await transport.connect(admission: admission, bearerToken: bearerToken, refreshAdmission: refreshAdmission)
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

    private func handle(_ event: SharedReadingSignalingEvent) async {
        guard !didFinish else { return }

        switch event {
        case .sessionState(let state):
            await applySessionState(state)
        case .syncFrame(let frame):
            guard acceptsSyncFrame(frame) else { return }
            sessionId = frame.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, frame.roomEpoch)
            controllerGeneration = max(controllerGeneration, frame.controllerGeneration)
            connectionGeneration = max(connectionGeneration, frame.connectionGeneration)
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
            guard transfer.roomEpoch >= roomEpoch else { return }
            sessionId = transfer.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, transfer.roomEpoch)
            controllerGeneration = max(controllerGeneration, transfer.controllerGeneration)
            connectionGeneration = max(connectionGeneration, transfer.connectionGeneration)
            currentParticipantUserId = transfer.toUserId
            lastAcceptedSyncSequence = -1
            latestProgress = nil
            publishSnapshot()
        case .participantRemove(let removal):
            guard removal.roomEpoch >= roomEpoch else { return }
            sessionId = removal.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, removal.roomEpoch)
            controllerGeneration = max(controllerGeneration, removal.controllerGeneration)
            connectionGeneration = max(connectionGeneration, removal.connectionGeneration)
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
            guard roster.roomEpoch >= roomEpoch, roster.rosterGeneration >= roomEpoch else { return }
            sessionId = roster.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, roster.roomEpoch)
            controllerGeneration = max(controllerGeneration, roster.controllerGeneration)
            connectionGeneration = max(connectionGeneration, roster.connectionGeneration)
            participants = roster.participants
            currentParticipantUserId = roster.participants.first(where: { $0.isController })?.userId ?? currentParticipantUserId
            publishSnapshot()
        case .speakerGranted(let granted):
            sessionId = granted.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, granted.roomEpoch)
            controllerGeneration = max(controllerGeneration, granted.controllerGeneration)
            connectionGeneration = max(connectionGeneration, granted.connectionGeneration)
            speakerUserId = granted.speakerUserId
            publishSnapshot()
        case .speakerReleased(let released):
            sessionId = released.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, released.roomEpoch)
            controllerGeneration = max(controllerGeneration, released.controllerGeneration)
            connectionGeneration = max(connectionGeneration, released.connectionGeneration)
            if speakerUserId == released.speakerUserId {
                speakerUserId = nil
            }
            publishSnapshot()
        case .sessionEnded(let ended):
            sessionId = ended.sessionId ?? sessionId
            roomEpoch = max(roomEpoch, ended.roomEpoch)
            controllerGeneration = max(controllerGeneration, ended.controllerGeneration)
            connectionGeneration = max(connectionGeneration, ended.connectionGeneration)
            await finishLocally(disconnectTransport: false)
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
        sessionId = state.sessionId ?? sessionId
        roomEpoch = state.roomEpoch
        controllerGeneration = state.controllerGeneration
        connectionGeneration = state.connectionGeneration
        status = state.status
        currentParticipantUserId = state.controllerUserId
        lastAcceptedSyncSequence = -1
        lastSentSyncSequence = -1
        latestProgress = nil
        participants = []
        publishSnapshot()

        if state.status == .ended {
            await finishLocally(disconnectTransport: false)
        }
    }

    private func acceptsSyncFrame(_ frame: SharedReadingSyncFrame) -> Bool {
        if let sessionId, let frameSessionId = frame.sessionId, sessionId != frameSessionId {
            return false
        }
        if frame.roomEpoch < roomEpoch {
            return false
        }
        if frame.roomEpoch > roomEpoch {
            return true
        }
        if frame.controllerGeneration < controllerGeneration {
            return false
        }
        if frame.controllerGeneration > controllerGeneration {
            return true
        }
        return frame.sequence > lastAcceptedSyncSequence
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

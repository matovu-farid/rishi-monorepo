import SwiftUI

/// The non-visual owner of a live shared-reading connection.  Keeping this
/// object separate from SwiftUI presentation means the normal reader can be
/// used on every platform without a sheet owning (and accidentally ending)
/// the session.
@MainActor
@Observable
final class SharedReadingSessionRuntime: SharedReadingSessionRegistryHandle {
    let api: SharedReadingAPI
    /// Captures the account that was admitted. Remote leave must never read a
    /// later account's Keychain token after a scene or sign-out race.
    let cleanupAPI: SharedReadingAPI
    let coordinator: SharedReadingSessionCoordinator
    let transport: any SharedReadingSignalingTransport
    let join: SharedReadingJoin
    let localParticipantUserID: String
    let accountID: UUID
    let requiresAuthoritativeRecovery: Bool
    let invitation: SharedReadingInvitation?

    private(set) var peerMesh: SharedReadingPeerMesh?
    private(set) var snapshot: SharedReadingSessionCoordinatorSnapshot?
    private(set) var roomStatus: SharedReadingRoomStatus?
    private(set) var message = "Connecting to the reading room…"
    private(set) var isConnected = false
    private(set) var connectionFailure: SharedReadingError?
    private(set) var voiceFailure: SharedReadingError?
    private(set) var isBusy = false
    private(set) var remoteAudioUserIDs = Set<String>()
    private(set) var recoveryReadiness = SharedReadingRecoveredSessionReadiness()
    private var readinessConnectionGeneration: SharedReadingConnectionGeneration?
    private var registration: SharedReadingSessionRegistry.Registration?
    private var stateTask: Task<Void, Never>?
    private var peerStateTask: Task<Void, Never>?
    private var remoteAudioTask: Task<Void, Never>?
    private var didCloseLocally = false
    private var didLeaveRemotely = false
    /// Set by `SharedReadingSessionRegistry` before it begins an account
    /// drain. It deliberately survives local close and unregistering so only
    /// the registry's bounded drain sends the corresponding HTTP leave.
    private var registryOwnsRemoteLeave = false
    private let sessionRegistry: SharedReadingSessionRegistry
    /// A runtime can outlive the view which redeemed it. Keep its connection
    /// account-scoped so an await resumed after sign-out can never register or
    /// present a room for the next account.
    private let isAccountCurrent: @MainActor @Sendable () -> Bool
    private let audioMixer = SharedReadingAudioMixer()

    init(api: SharedReadingAPI, cleanupAPI: SharedReadingAPI,
         coordinator: SharedReadingSessionCoordinator,
         transport: any SharedReadingSignalingTransport, join: SharedReadingJoin,
         localParticipantUserID: String, accountID: UUID,
         sessionRegistry: SharedReadingSessionRegistry,
         requiresAuthoritativeRecovery: Bool = false,
         invitation: SharedReadingInvitation? = nil,
         isAccountCurrent: @escaping @MainActor @Sendable () -> Bool) {
        self.api = api; self.cleanupAPI = cleanupAPI
        self.coordinator = coordinator; self.transport = transport
        self.join = join; self.localParticipantUserID = localParticipantUserID
        self.accountID = accountID; self.sessionRegistry = sessionRegistry
        self.requiresAuthoritativeRecovery = requiresAuthoritativeRecovery; self.invitation = invitation
        self.isAccountCurrent = isAccountCurrent
    }

    var readerContext: SharedReadingReaderContext? {
        guard isConnected, !didCloseLocally, canUseSessionControls,
              isAccountCurrent(), let registration,
              sessionRegistry.isCurrent(registration)
        else { return nil }
        return SharedReadingReaderContext(runtime: self)
    }

    /// Retains a just-admitted participant before any later suspension point.
    /// This closes the small gap between `/rejoin` succeeding on the server
    /// and the signaling connection being established: an account transition
    /// can now drain this owner even if setup never reaches `connectAndPrepare`.
    ///
    /// Deliberately do not register an already-stale account. In that case the
    /// caller owns one scoped best-effort `leave` instead of attaching an old
    /// admission to a generation that has already been drained.
    func retainAdmission() {
        guard registration == nil, !didCloseLocally, isAccountCurrent() else { return }
        registration = sessionRegistry.register(self, accountID: accountID)
    }

    /// This remains true after local close and registry unregistering. It is
    /// the durable ownership signal for a transition's bounded remote leave.
    var isRegistryDrainRemoteLeaveOwned: Bool { registryOwnsRemoteLeave }
    /// Reconnect work uses the same existing closed/account fence as setup.
    var canRefreshAdmission: Bool { !didCloseLocally && isAccountCurrent() }
    var currentStatus: SharedReadingSessionStatus { snapshot?.status ?? join.admission.status }
    var isLocalController: Bool { (snapshot?.currentParticipantUserId ?? roomStatus?.controllerUserId) == localParticipantUserID }
    var visibleParticipants: [SharedReadingParticipant] { !(snapshot?.participants.isEmpty ?? true) ? snapshot!.participants : (roomStatus?.participants ?? []) }
    var removedParticipantIDs: Set<String> { Set(roomStatus?.removedUserIds ?? []) }
    var canUseSessionControls: Bool { isConnected && connectionFailure == nil && recoveryReadiness.isReady }

    func connectAndPrepare() async throws {
        try requireCurrentAccount()
        connectionFailure = nil
        voiceFailure = nil
        retainAdmission()
        try requireCurrentAccount()
        do {
            Log.sharedReading(.sessionLifecycle, context: .init(outcome: .started, sessionID: join.response.sessionId))
            try await coordinator.connect(admission: join.admission, bearerToken: try await api.bearerToken())
            try requireCurrentAccount()
            let status = try await api.status(sessionId: join.response.sessionId)
            try requireCurrentAccount()
            let mesh = SharedReadingPeerMesh(localParticipantUserId: localParticipantUserID, signaling: transport)
            peerMesh = mesh
            await mesh.setMicrophoneEnabled(SharedReadingMicrophonePolicyState().microphoneEnabled(isTTSPlaying: false))
            roomStatus = status
            var turnCredentials: SharedReadingTurnCredentials?
            do {
                turnCredentials = try await api.turnCredentials(sessionId: join.response.sessionId)
            } catch let error as SharedReadingError {
                guard error.code != .authRequired else { throw error }
                retainOptionalVoiceFailure(error, fallbackStage: "turn.credentials")
            } catch {
                retainOptionalVoiceFailure(.init(
                    code: .turnUnavailable,
                    message: SharedReadingError.from(code: .turnUnavailable).message,
                    retryable: true,
                    action: .retry,
                    stage: "turn.credentials",
                    diagnostic: "UNKNOWN"
                ), fallbackStage: "turn.credentials")
            }
            if let turnCredentials {
                do {
                    try await mesh.start(participants: status.participants, turnCredentials: turnCredentials)
                } catch let error as SharedReadingError {
                    guard error.code != .authRequired else { throw error }
                    retainOptionalVoiceFailure(error, fallbackStage: "voice.peer_mesh")
                } catch {
                    retainOptionalVoiceFailure(.init(
                        code: .rtcConnectionFailed,
                        message: SharedReadingError.from(code: .rtcConnectionFailed).message,
                        retryable: true,
                        action: .retry,
                        stage: "voice.peer_mesh",
                        diagnostic: "UNKNOWN"
                    ), fallbackStage: "voice.peer_mesh")
                }
            }
            try requireCurrentAccount()
            startObservers(mesh: mesh)
            try await waitForAuthoritativeRecoveryReadiness()
            try requireCurrentAccount()
            if let connectionFailure { throw connectionFailure }
            isConnected = true
            if let voiceFailure {
#if DEBUG
                message = voiceFailure.debugPresentationMessage()
#else
                message = "Connected, but voice is unavailable right now."
#endif
            } else {
                message = "Connected"
            }
        } catch {
            await closeLocally()
            throw error
        }
    }

    private func requireCurrentAccount() throws {
        guard !didCloseLocally, isAccountCurrent() else {
            throw SharedReadingError.from(code: .serviceUnavailable)
        }
    }

    private func retainOptionalVoiceFailure(_ error: SharedReadingError, fallbackStage: String) {
        let retained = SharedReadingError(
            code: error.code,
            message: error.message,
            retryable: error.retryable,
            action: error.action,
            correlationId: error.correlationId,
            stage: error.stage ?? fallbackStage,
            httpStatus: error.httpStatus,
            diagnostic: error.diagnostic,
            localSocketCode: error.localSocketCode
        )
        voiceFailure = retained
        let stage = (retained.stage ?? fallbackStage).uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let diagnosticCode = String("VOICE_\(String(stage.prefix(24)))_\(retained.code.rawValue)".prefix(64))
        Log.sharedReading(
            fallbackStage.hasPrefix("turn.") ? .apiFailure : .recovery,
            level: .error,
            context: .init(
                operation: .turn,
                outcome: .failed,
                correlationID: retained.correlationId,
                sessionID: join.response.sessionId,
                statusCode: retained.httpStatus,
                errorCode: diagnosticCode
            )
        )
    }

    /// Every join, not only recovery, must prove a live signaling handshake.
    /// An open URLSessionWebSocketTask is not proof that its one-use admission
    /// was accepted by the room. Bound the wait so an offline reader cannot
    /// be presented as if it were synchronized.
    private func waitForAuthoritativeRecoveryReadiness() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !recoveryReadiness.isReady {
            try Task.checkCancellation()
            try requireCurrentAccount()
            if let connectionFailure { throw connectionFailure }
            if snapshot?.status == .ended {
                throw SharedReadingError.from(code: .sessionEnded)
            }
            if ContinuousClock.now >= deadline {
                if let failure = await coordinator.latestTransportFailure() {
                    throw failure
                }
                let diagnostic = recoveryReadiness.missingEvidenceDiagnostic
                let correlationID = await transport.latestHandshakeCorrelationID()
                let failure = SharedReadingError(
                    code: .signalingDegraded,
                    message: "The reading room did not confirm synchronization. Check your connection and try joining again.",
                    retryable: true,
                    action: .retry,
                    correlationId: correlationID,
                    stage: "readiness.authoritative_sync",
                    diagnostic: diagnostic
                )
                Log.sharedReading(.recovery, level: .error, context: .init(
                    operation: invitation == nil ? (requiresAuthoritativeRecovery ? .rejoin : .redeem) : .create,
                    outcome: .failed,
                    correlationID: failure.correlationId,
                    sessionID: join.response.sessionId,
                    roomEpoch: snapshot?.roomEpoch.rawValue,
                    connectionGeneration: snapshot?.connectionGeneration.rawValue,
                    errorCode: failure.code.rawValue,
                    diagnostic: failure.diagnostic,
                    stage: failure.stage
                ))
                throw failure
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func startObservers(mesh: SharedReadingPeerMesh) {
        stateTask?.cancel(); peerStateTask?.cancel(); remoteAudioTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await next in coordinator.stateUpdates {
                guard !Task.isCancelled else { return }
                snapshot = next
                if let failure = next.signalingFailure {
                    connectionFailure = failure
                    isConnected = false
                    recoveryReadiness.begin(roomEpoch: next.roomEpoch)
                    message = failure.retryable
                        ? "\(failure.presentationMessage) Leave and rejoin the reading session."
                        : failure.presentationMessage
                    continue
                }
                if next.roomEpoch != recoveryReadiness.roomEpoch || next.connectionGeneration != readinessConnectionGeneration {
                    recoveryReadiness.begin(roomEpoch: next.roomEpoch)
                    readinessConnectionGeneration = next.connectionGeneration
                }
                if next.sessionId == join.response.sessionId {
                    if next.hasAuthoritativeState { recoveryReadiness.accept(.state) }
                    if next.hasAuthoritativeRoster { recoveryReadiness.accept(.roster) }
                    if let progress = next.latestProgress { recoveryReadiness.accept(.progressPresent(sequence: progress.sequence)) }
                    else if next.authoritativeProgressIsAbsent { recoveryReadiness.accept(.progressAbsent) }
                }
                connectionFailure = nil
                switch next.status { case .active: message = "Reading session is active"; case .waiting: message = "Waiting for the initial sharer"; case .ended: message = "This reading session has ended"; isConnected = false }
            }
        }
        peerStateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in mesh.peerStates {
                guard !Task.isCancelled else { return }
                audioMixer.consume(peerState: event)
                remoteAudioUserIDs = audioMixer.snapshot().remoteAudioUserIds
            }
        }
        remoteAudioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in mesh.remoteAudioEvents {
                guard !Task.isCancelled else { return }
                audioMixer.consume(remoteAudio: event)
                remoteAudioUserIDs = audioMixer.snapshot().remoteAudioUserIds
            }
        }
    }

    func start() async { await perform { try await self.coordinator.start() } }
    /// Returning a result keeps UI navigation separate from a failed end
    /// request: a controller remains in the room until ending is confirmed.
    @discardableResult
    func end() async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await coordinator.end()
            message = "Reading session ended"
            return true
        } catch let error as SharedReadingError {
            message = error.presentationMessage
        } catch {
#if DEBUG
            message = "Rishi could not complete that session action: \(String(describing: error))"
#else
            message = "Rishi could not complete that session action."
#endif
        }
        return false
    }
    func leave() async { await coordinator.leave(); await closeLocally(); await leaveRemotelyOnce() }
    func transferController(to participant: SharedReadingParticipant) async { await perform { _ = try await self.api.transferController(sessionId: self.join.response.sessionId, targetUserId: participant.userId); await self.refreshStatus("Controller transferred to \(participant.displayName)") } }
    func remove(_ participant: SharedReadingParticipant) async { await perform { _ = try await self.api.removeParticipant(sessionId: self.join.response.sessionId, participantUserId: participant.userId); await self.refreshStatus("\(participant.displayName) was removed") } }
    func restore(userID: String) async { await perform { _ = try await self.api.restoreParticipant(sessionId: self.join.response.sessionId, participantUserId: userID, contentHash: self.join.response.book.contentHash); await self.refreshStatus("Participant restored") } }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
        } catch let error as SharedReadingError {
            message = error.presentationMessage
        } catch {
#if DEBUG
            message = "Rishi could not complete that session action: \(String(describing: error))"
#else
            message = "Rishi could not complete that session action."
#endif
        }
    }
    private func refreshStatus(_ next: String) async { roomStatus = try? await api.status(sessionId: join.response.sessionId); message = next }

    func claimRegistryDrainRemoteLeaveOwnership() {
        registryOwnsRemoteLeave = true
    }

    func cancelLocally() async { await closeLocally() }
    func leaveRemotely() async { await leaveRemotelyOnce(allowRegistryOwnedLeave: true) }
    func closeLocally() async {
        guard !didCloseLocally else { return }; didCloseLocally = true; isConnected = false
        stateTask?.cancel(); peerStateTask?.cancel(); remoteAudioTask?.cancel()
        if let registration { sessionRegistry.unregister(registration); self.registration = nil }
        await peerMesh?.close(); await coordinator.cancelLocally(); await transport.disconnect()
    }
    func leaveRemotelyOnce(allowRegistryOwnedLeave: Bool = false) async {
        guard !registryOwnsRemoteLeave || allowRegistryOwnedLeave else { return }
        guard !didLeaveRemotely else { return }; didLeaveRemotely = true
        _ = try? await cleanupAPI.leave(sessionId: join.response.sessionId, deliberate: true)
    }
    func leaveAndClose() async { await closeLocally(); await leaveRemotelyOnce() }
}

@MainActor
struct SharedReadingReaderContext {
    let runtime: SharedReadingSessionRuntime
    var coordinator: SharedReadingSessionCoordinator { runtime.coordinator }
    var join: SharedReadingJoin { runtime.join }
    var peerMesh: SharedReadingPeerMesh? { runtime.peerMesh }
    var localUserID: String { runtime.localParticipantUserID }
}

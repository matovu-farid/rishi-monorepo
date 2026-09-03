import Foundation
@preconcurrency import LiveKitWebRTC

enum SharedReadingPeerConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

struct SharedReadingPeerStateEvent: Sendable, Equatable {
    let userId: String
    let state: SharedReadingPeerConnectionState
    let errorMessage: String?
}

struct SharedReadingDataChannelEvent: Sendable, Equatable {
    let userId: String
    let data: Data
    let isBinary: Bool
}

struct SharedReadingRemoteAudioTrack: @unchecked Sendable {
    let userId: String
    let track: LKRTCAudioTrack
}

actor SharedReadingPeerMesh {
    nonisolated let peerStates: AsyncStream<SharedReadingPeerStateEvent>
    nonisolated let dataChannelEvents: AsyncStream<SharedReadingDataChannelEvent>
    nonisolated let remoteAudioTracks: AsyncStream<SharedReadingRemoteAudioTrack>

    nonisolated var dataEvents: AsyncStream<SharedReadingDataChannelEvent> { dataChannelEvents }
    nonisolated var remoteAudioEvents: AsyncStream<SharedReadingRemoteAudioTrack> { remoteAudioTracks }

    private let localUserId: String
    private let signaling: any SharedReadingSignalingTransport
    private let factory: LKRTCPeerConnectionFactory

    private let peerStateContinuation: AsyncStream<SharedReadingPeerStateEvent>.Continuation
    private let dataEventContinuation: AsyncStream<SharedReadingDataChannelEvent>.Continuation
    private let remoteAudioContinuation: AsyncStream<SharedReadingRemoteAudioTrack>.Continuation

    private var peers: [String: SharedReadingPeerConnection] = [:]
    private var participants: [String: SharedReadingParticipant] = [:]
    private var turnServers: [LKRTCIceServer] = []
    private var signalingTask: Task<Void, Never>?
    private var dataEventTasks: [String: Task<Void, Never>] = [:]
    private var microphoneEnabled = false
    private var isStarted = false
    private var isClosed = false

    init(
        localUserId: String,
        signaling: any SharedReadingSignalingTransport,
        factory: LKRTCPeerConnectionFactory? = nil
    ) {
        self.localUserId = localUserId
        self.signaling = signaling
        if let factory {
            self.factory = factory
        } else {
            LKRTCInitializeSSL()
            self.factory = LKRTCPeerConnectionFactory()
        }

        var peerStateContinuation: AsyncStream<SharedReadingPeerStateEvent>.Continuation!
        self.peerStates = AsyncStream { peerStateContinuation = $0 }
        self.peerStateContinuation = peerStateContinuation

        var dataEventContinuation: AsyncStream<SharedReadingDataChannelEvent>.Continuation!
        self.dataChannelEvents = AsyncStream { dataEventContinuation = $0 }
        self.dataEventContinuation = dataEventContinuation

        var remoteAudioContinuation: AsyncStream<SharedReadingRemoteAudioTrack>.Continuation!
        self.remoteAudioTracks = AsyncStream { remoteAudioContinuation = $0 }
        self.remoteAudioContinuation = remoteAudioContinuation
    }

    init(
        localParticipantUserId: String,
        signaling: any SharedReadingSignalingTransport,
        factory: LKRTCPeerConnectionFactory? = nil
    ) {
        self.init(localUserId: localParticipantUserId, signaling: signaling, factory: factory)
    }

    func start(
        participants: [SharedReadingParticipant],
        turnCredentials: SharedReadingTurnCredentials
    ) async throws {
        guard !isClosed else {
            throw SharedReadingError.from(code: .sessionEnded)
        }

        let participantMap = try validate(participants)
        let iceServers = CloudflareTurnProvider.iceServers(from: turnCredentials)
        guard !iceServers.isEmpty else {
            throw SharedReadingError.from(code: .turnUnavailable)
        }

        await tearDownPeers()
        turnServers = iceServers
        self.participants = participantMap
        isStarted = true
        startSignalingObservationIfNeeded()
        try await installPeers(for: participantMap)
    }

    func updateParticipants(_ participants: [SharedReadingParticipant]) async {
        guard !isClosed else { return }

        guard let participantMap = try? validate(participants) else {
            for participant in participants where participant.userId != localUserId {
                emitState(for: participant.userId, state: .failed, errorMessage: "The reading room is full or contains duplicate participants.")
            }
            return
        }

        self.participants = participantMap
        guard isStarted else { return }

        let desiredUserIds = Set(participantMap.keys)
        for userId in Array(peers.keys) where !desiredUserIds.contains(userId) {
            removePeer(userId, state: .closed)
        }

        for (userId, participant) in participantMap where peers[userId] == nil {
            do {
                try await installPeer(participant)
            } catch {
                emitState(for: userId, state: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async {
        microphoneEnabled = enabled
        for peer in peers.values {
            peer.setMicrophoneEnabled(enabled)
        }
    }

    func sendData(_ data: Data, to userId: String, isBinary: Bool = true) throws {
        guard let peer = peers[userId], let channel = peer.dataChannel else {
            throw SharedReadingError.from(code: .rtcConnectionFailed, message: "The peer data channel is not ready.")
        }
        guard channel.send(data, isBinary: isBinary) else {
            throw SharedReadingError.from(code: .rtcConnectionFailed, message: "The peer data channel is not open.")
        }
    }

    func sendData(_ data: Data, toUserId userId: String, isBinary: Bool = true) throws {
        try sendData(data, to: userId, isBinary: isBinary)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        isStarted = false
        signalingTask?.cancel()
        signalingTask = nil
        await tearDownPeers()
        peerStateContinuation.finish()
        dataEventContinuation.finish()
        remoteAudioContinuation.finish()
    }

    private func validate(_ participants: [SharedReadingParticipant]) throws -> [String: SharedReadingParticipant] {
        guard participants.count <= 5 else {
            throw SharedReadingError.from(code: .roomFull)
        }

        var result: [String: SharedReadingParticipant] = [:]
        for participant in participants where participant.userId != localUserId && participant.connectionState == "connected" {
            guard result[participant.userId] == nil else {
                throw SharedReadingError.from(code: .serviceUnavailable, message: "The participant list contains duplicate users.")
            }
            result[participant.userId] = participant
        }

        guard result.count <= 4 else {
            throw SharedReadingError.from(code: .roomFull)
        }
        return result
    }

    private func startSignalingObservationIfNeeded() {
        guard signalingTask == nil else { return }

        signalingTask = Task { [weak self, signaling] in
            for await event in signaling.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func installPeers(for participantMap: [String: SharedReadingParticipant]) async throws {
        for participant in participantMap.values.sorted(by: { $0.userId < $1.userId }) {
            do {
                try await installPeer(participant)
            } catch {
                emitState(for: participant.userId, state: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    private func installPeer(_ participant: SharedReadingParticipant) async throws {
        let userId = participant.userId
        guard peers[userId] == nil else { return }

        let isOfferer = localUserId < userId
        let peer = try SharedReadingPeerConnection(
            remoteUserId: userId,
            isOfferer: isOfferer,
            iceServers: turnServers,
            localMicrophoneEnabled: microphoneEnabled,
            factory: factory,
            owner: self
        )
        peers[userId] = peer
        emitState(for: userId, state: .connecting, errorMessage: nil)
        observeDataChannelIfPresent(for: peer)

        if isOfferer {
            do {
                let sdp = try await peer.makeOffer()
                try await signaling.send(.sdpOffer(toUserId: userId, sdp: sdp))
            } catch {
                handlePeerFailure(userId: userId, error: error)
            }
        }
    }

    private func observeDataChannelIfPresent(for peer: SharedReadingPeerConnection) {
        guard let channel = peer.dataChannel else { return }
        observeDataChannel(channel)
    }

    private func observeDataChannel(_ channel: SharedReadingDataChannel) {
        let userId = channel.remoteUserId
        dataEventTasks[userId]?.cancel()
        dataEventTasks[userId] = Task { [weak self, channel] in
            for await event in channel.events {
                guard !Task.isCancelled else { return }
                if case .data(let data, let isBinary) = event {
                    await self?.receiveData(data, from: userId, isBinary: isBinary)
                }
            }
        }
    }

    private func handle(_ event: SharedReadingSignalingEvent) async {
        guard !isClosed else { return }

        switch event {
        case .sdpOffer(let offer):
            guard let peer = peers[offer.fromUserId] else { return }
            do {
                let answer = try await peer.applyRemoteDescription(
                    LKRTCSessionDescription(type: .offer, sdp: offer.sdp)
                )
                try await signaling.send(.sdpAnswer(toUserId: offer.fromUserId, sdp: answer))
            } catch {
                handlePeerFailure(userId: offer.fromUserId, error: error)
            }
        case .sdpAnswer(let answer):
            guard let peer = peers[answer.fromUserId] else { return }
            do {
                _ = try await peer.applyRemoteDescription(
                    LKRTCSessionDescription(type: .answer, sdp: answer.sdp)
                )
            } catch {
                handlePeerFailure(userId: answer.fromUserId, error: error)
            }
        case .ice(let ice):
            guard let peer = peers[ice.fromUserId] else { return }
            do {
                try await peer.addRemoteCandidate(ice.candidate)
            } catch {
                handlePeerFailure(userId: ice.fromUserId, error: error)
            }
        case .participantRemove(let removal):
            removePeer(removal.userId, state: .closed)
        case .participantRoster(let roster):
            await updateParticipants(roster.participants)
        case .sessionEnded:
            await close()
        case .error(let error) where error.code == .sessionEnded || error.code == .removedFromSession:
            await close()
        case .sessionState, .syncFrame, .controllerTransfer, .speakerGranted, .speakerReleased, .error:
            break
        }
    }

    private func tearDownPeers() async {
        for userId in Array(peers.keys) {
            removePeer(userId, state: .closed)
        }
        for task in dataEventTasks.values {
            task.cancel()
        }
        dataEventTasks.removeAll()
    }

    private func removePeer(_ userId: String, state: SharedReadingPeerConnectionState) {
        guard let peer = peers.removeValue(forKey: userId) else { return }
        dataEventTasks[userId]?.cancel()
        dataEventTasks[userId] = nil
        peer.close()
        emitState(for: userId, state: state, errorMessage: nil)
    }

    private func handlePeerFailure(userId: String, error: Error) {
        guard peers[userId] != nil else { return }
        let message = error.localizedDescription
        peers[userId]?.close()
        peers[userId] = nil
        dataEventTasks[userId]?.cancel()
        dataEventTasks[userId] = nil
        emitState(for: userId, state: .failed, errorMessage: message)
    }

    private func emitState(
        for userId: String,
        state: SharedReadingPeerConnectionState,
        errorMessage: String?
    ) {
        peerStateContinuation.yield(SharedReadingPeerStateEvent(userId: userId, state: state, errorMessage: errorMessage))
    }

    private func receiveData(_ data: Data, from userId: String, isBinary: Bool) {
        dataEventContinuation.yield(SharedReadingDataChannelEvent(userId: userId, data: data, isBinary: isBinary))
    }

    fileprivate func peerStateChanged(userId: String, state: SharedReadingPeerConnectionState) {
        guard !isClosed, peers[userId] != nil else { return }
        emitState(for: userId, state: state, errorMessage: nil)
        if state == .failed {
            peers[userId]?.close()
            peers[userId] = nil
            dataEventTasks[userId]?.cancel()
            dataEventTasks[userId] = nil
        }
    }

    fileprivate func dataChannelOpened(_ channel: SharedReadingDataChannel) {
        observeDataChannel(channel)
    }

    fileprivate func remoteAudioTrackReceived(userId: String, track: LKRTCAudioTrack) {
        guard !isClosed else { return }
        remoteAudioContinuation.yield(SharedReadingRemoteAudioTrack(userId: userId, track: track))
    }
}

private final class SharedReadingPeerConnection: NSObject, @unchecked Sendable {
    let remoteUserId: String
    private(set) var dataChannel: SharedReadingDataChannel?

    private let connection: LKRTCPeerConnection
    private let localAudioTrack: LKRTCAudioTrack
    private weak var owner: SharedReadingPeerMesh?
    private var remoteAudioTracks: [String: LKRTCAudioTrack] = [:]
    private var pendingCandidates: [LKRTCIceCandidate] = []
    private var hasRemoteDescription = false

    init(
        remoteUserId: String,
        isOfferer: Bool,
        iceServers: [LKRTCIceServer],
        localMicrophoneEnabled: Bool,
        factory: LKRTCPeerConnectionFactory,
        owner: SharedReadingPeerMesh
    ) throws {
        self.remoteUserId = remoteUserId
        self.owner = owner

        let configuration = LKRTCConfiguration()
        configuration.iceServers = iceServers
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw SharedReadingError.from(code: .rtcConnectionFailed)
        }
        self.connection = connection

        let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
            mandatoryConstraints: [
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true",
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
            ],
            optionalConstraints: nil
        ))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "shared_reading_audio_\(UUID().uuidString)")
        audioTrack.isEnabled = localMicrophoneEnabled
        guard connection.add(audioTrack, streamIds: ["shared_reading_stream"]) != nil else {
            throw SharedReadingError.from(code: .rtcConnectionFailed)
        }
        self.localAudioTrack = audioTrack

        if isOfferer {
            let dataChannelConfiguration = LKRTCDataChannelConfiguration()
            dataChannelConfiguration.isOrdered = true
            guard let channel = connection.dataChannel(forLabel: "shared-reading", configuration: dataChannelConfiguration) else {
                throw SharedReadingError.from(code: .rtcConnectionFailed)
            }
            self.dataChannel = SharedReadingDataChannel(channel: channel, remoteUserId: remoteUserId)
        } else {
            self.dataChannel = nil
        }

        super.init()
        connection.delegate = self
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        localAudioTrack.isEnabled = enabled
    }

    func makeOffer() async throws -> String {
        let offer = try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(offer)
        return offer.sdp
    }

    func applyRemoteDescription(_ description: LKRTCSessionDescription) async throws -> String {
        try await connection.setRemoteDescription(description)
        hasRemoteDescription = true
        for candidate in pendingCandidates {
            try await add(candidate)
        }
        pendingCandidates.removeAll()

        guard description.type == .offer else { return "" }
        let answer = try await connection.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await connection.setLocalDescription(answer)
        return answer.sdp
    }

    func addRemoteCandidate(_ candidate: SharedReadingICECandidate) async throws {
        let iceCandidate = LKRTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        guard hasRemoteDescription else {
            pendingCandidates.append(iceCandidate)
            return
        }
        try await add(iceCandidate)
    }

    func close() {
        dataChannel?.close()
        connection.close()
    }

    private func add(_ candidate: LKRTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension SharedReadingPeerConnection: LKRTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    func peerConnection(_: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        for track in stream.audioTracks {
            receive(track)
        }
    }

    func peerConnection(_: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        guard dataChannel.label == "shared-reading" else { return }
        let channel = SharedReadingDataChannel(channel: dataChannel, remoteUserId: remoteUserId)
        self.dataChannel = channel
        Task { [weak owner] in
            guard let owner else { return }
            await owner.dataChannelOpened(channel)
        }
    }

    func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}

    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}

    func peerConnection(_: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let message = SharedReadingICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        Task { [weak owner] in
            try? await owner?.sendLocalICE(to: remoteUserId, candidate: message)
        }
    }

    func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}

    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

    func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        let state: SharedReadingPeerConnectionState
        switch newState {
        case .connected, .completed: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        default: state = .connecting
        }
        Task { [weak owner] in
            await owner?.peerStateChanged(userId: remoteUserId, state: state)
        }
    }

    func peerConnection(_: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        guard let track = receiver.track as? LKRTCAudioTrack else { return }
        receive(track)
    }

    private func receive(_ track: LKRTCAudioTrack) {
        guard remoteAudioTracks[track.trackId] == nil else { return }
        remoteAudioTracks[track.trackId] = track
        Task { [weak owner] in
            await owner?.remoteAudioTrackReceived(userId: remoteUserId, track: track)
        }
    }
}

private extension SharedReadingPeerMesh {
    func sendLocalICE(to userId: String, candidate: SharedReadingICECandidate) async throws {
        guard !isClosed, peers[userId] != nil else { return }
        do {
            try await signaling.send(.ice(toUserId: userId, candidate: candidate))
        } catch {
            handlePeerFailure(userId: userId, error: error)
        }
    }
}

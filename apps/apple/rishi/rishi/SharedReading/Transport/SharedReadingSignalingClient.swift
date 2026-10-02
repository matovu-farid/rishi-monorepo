import Foundation
import ReadiumShared

protocol SharedReadingSignalingTransport: Sendable {
    var events: AsyncStream<SharedReadingSignalingEvent> { get }

    func connect(
        admission: SharedReadingAdmission,
        bearerToken: String,
        refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?,
        refreshBearerToken: (@Sendable () async throws -> String)?
    ) async throws
    func disconnect() async
    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws
    func confirmAuthoritativeSessionState(_ state: SharedReadingSessionStateEvent) async
    func latestHandshakeCorrelationID() async -> String?
}

extension SharedReadingSignalingTransport {
    func confirmAuthoritativeSessionState(_ state: SharedReadingSessionStateEvent) async {}
    func latestHandshakeCorrelationID() async -> String? { nil }
}

enum SharedReadingSignalingEvent: Sendable, Equatable {
    case sessionState(SharedReadingSessionStateEvent)
    case syncFrame(SharedReadingSyncFrame)
    case syncAbsent(SharedReadingSyncAbsentEvent)
    case controllerTransfer(SharedReadingControllerTransferEvent)
    case participantRemove(SharedReadingParticipantRemoveEvent)
    case participantRoster(SharedReadingParticipantRosterEvent)
    case speakerGranted(SharedReadingSpeakerGrantedEvent)
    case speakerReleased(SharedReadingSpeakerReleasedEvent)
    case sessionEnded(SharedReadingSessionEndedEvent)
    case sdpOffer(SharedReadingSDPEvent)
    case sdpAnswer(SharedReadingSDPEvent)
    case ice(SharedReadingICEEvent)
    case error(SharedReadingError)
}

struct SharedReadingSyncAbsentEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
}

struct SharedReadingSignalFence: Codable, Sendable, Equatable {
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
}

struct SharedReadingSessionStateEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let status: SharedReadingSessionStatus
    let controllerUserId: String
}

struct SharedReadingSyncFrame: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let sequence: Int64
    let bookId: String
    let contentHash: String
    let format: SharedReadingBookFormat
    let position: String
    let isPlaying: Bool
    let ttsRate: Double

    private enum CodingKeys: String, CodingKey {
        case sessionId, roomEpoch, controllerGeneration, connectionGeneration, sequence, bookId, contentHash, position, isPlaying, ttsRate
        case format
    }

    init(
        sessionId: String?,
        roomEpoch: SharedReadingRoomEpoch,
        controllerGeneration: SharedReadingControllerGeneration,
        connectionGeneration: SharedReadingConnectionGeneration,
        sequence: Int64,
        bookId: String,
        contentHash: String,
        format: SharedReadingBookFormat,
        position: String,
        isPlaying: Bool,
        ttsRate: Double
    ) {
        self.sessionId = sessionId
        self.roomEpoch = roomEpoch
        self.controllerGeneration = controllerGeneration
        self.connectionGeneration = connectionGeneration
        self.sequence = sequence
        self.bookId = bookId
        self.contentHash = contentHash
        self.format = format
        self.position = position
        self.isPlaying = isPlaying
        self.ttsRate = ttsRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        roomEpoch = try c.decodeIfPresent(SharedReadingRoomEpoch.self, forKey: .roomEpoch) ?? 0
        controllerGeneration = try c.decodeIfPresent(SharedReadingControllerGeneration.self, forKey: .controllerGeneration) ?? 0
        connectionGeneration = try c.decodeIfPresent(SharedReadingConnectionGeneration.self, forKey: .connectionGeneration) ?? 0
        sequence = try c.decode(Int64.self, forKey: .sequence)
        bookId = try c.decode(String.self, forKey: .bookId)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        format = try c.decodeIfPresent(SharedReadingBookFormat.self, forKey: .format) ?? .epub
        if let text = try? c.decode(String.self, forKey: .position) {
            position = text
        } else {
            let object = try c.decode(SharedReadingWirePositionPayload.self, forKey: .position)
            position = try Self.locatorJSONString(from: object)
        }
        isPlaying = try c.decode(Bool.self, forKey: .isPlaying)
        ttsRate = try c.decode(Double.self, forKey: .ttsRate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(roomEpoch, forKey: .roomEpoch)
        try c.encode(controllerGeneration, forKey: .controllerGeneration)
        try c.encode(connectionGeneration, forKey: .connectionGeneration)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(bookId, forKey: .bookId)
        try c.encode(contentHash, forKey: .contentHash)
        try c.encode(format, forKey: .format)
        try c.encode(position, forKey: .position)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(ttsRate, forKey: .ttsRate)
    }

    private static func locatorJSONString(from payload: SharedReadingWirePositionPayload) throws -> String {
        if let native = payload.readiumLocator {
            guard !native.isEmpty, native.utf8.count <= SharedReadingWirePosition.maxLocatorBytes,
                  let locator = try? Locator(jsonString: native), !locator.href.string.isEmpty else {
                throw SharedReadingError.from(code: .serviceUnavailable, message: "The shared reading position is invalid.")
            }
            return try ReaderPositionLocator(locator: locator, source: payload.positionSource ?? .reader).encodedJSONString()
        }
        // A legacy frame has no publication resource href. Keep its metadata
        // for a publication-backed PDF fallback in the reader, but never make
        // an href-empty Readium Locator which could jump to the wrong chapter.
        guard payload.format != .pdf || (payload.page ?? -1) >= 0 else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "The shared PDF page is invalid.")
        }
        let data = try JSONEncoder().encode(payload)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "The shared reading position is invalid.")
        }
        return value
    }
}

private struct SharedReadingWirePositionPayload: Codable {
    let format: SharedReadingBookFormat
    let cfi: String?
    let page: Int?
    let offsetY: Double?
    let readiumLocator: String?
    let positionSource: ReaderPositionLocator.Source?
}

struct SharedReadingControllerTransferEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let fromUserId: String?
    let toUserId: String
}

enum SharedReadingParticipantRemovalReason: String, Codable, Sendable, Equatable {
    case removed
    case kicked
    case left
    case dropped
}

struct SharedReadingParticipantRemoveEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let userId: String
    let reason: SharedReadingParticipantRemovalReason
}

struct SharedReadingParticipantRosterEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let rosterGeneration: SharedReadingRosterGeneration
    let participants: [SharedReadingParticipant]
}

struct SharedReadingSpeakerGrantedEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let requestId: String?
    let speakerUserId: String
}

struct SharedReadingSpeakerReleasedEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let speakerUserId: String
}

enum SharedReadingSessionEndedReason: String, Codable, Sendable, Equatable {
    case controllerEnded = "controller_ended"
    case roomExpired = "room_expired"
    case hostLeft = "host_left"
    case hostEnded = "host_ended"
    case hostGraceExpired = "host_grace_expired"
}

struct SharedReadingSessionEndedEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let reason: SharedReadingSessionEndedReason
}

struct SharedReadingSDPEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let fromUserId: String
    let sdp: String

    private enum CodingKeys: String, CodingKey {
        case sessionId, roomEpoch, controllerGeneration, connectionGeneration
        case fromUserId = "from"
        case sdp
    }
}

struct SharedReadingICECandidate: Codable, Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

struct SharedReadingICEEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let fromUserId: String
    let candidate: SharedReadingICECandidate

    private enum CodingKeys: String, CodingKey {
        case sessionId, roomEpoch, controllerGeneration, connectionGeneration
        case fromUserId = "from"
        case candidate
    }
}

enum SharedReadingSignalingOutgoingMessage: Sendable, Equatable {
    case sessionStart(SharedReadingSignalFence)
    case leave(SharedReadingSignalFence)
    case end(SharedReadingSignalFence)
    case speakerRequest(SharedReadingSignalFence, requestId: String)
    case speakerRelease(SharedReadingSignalFence)
    case syncFrame(SharedReadingSyncFrame)
    case sdpOffer(toUserId: String, sdp: String)
    case sdpAnswer(toUserId: String, sdp: String)
    case ice(toUserId: String, candidate: SharedReadingICECandidate)

    fileprivate func encoded(maxFrameBytes: Int) throws -> Data {
        let data = try JSONEncoder().encode(OutgoingEnvelope(message: self))
        let frameLimit: Int
        if case .syncFrame = self { frameLimit = min(maxFrameBytes, 16 * 1024) }
        else { frameLimit = maxFrameBytes }
        guard data.count <= frameLimit else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading frame exceeded the room limit.")
        }
        return data
    }
}

private enum SharedReadingWireCodingKeys: String, CodingKey {
    case v
    case t
    case frame
    case sessionId
    case roomEpoch
    case controllerGeneration
    case connectionGeneration
    case fromUserId
    case toUserId
    case userId
    case reason
    case requestId
    case to
    case speakerUserId
    case sequence
    case bookId
    case contentHash
    case position
    case isPlaying
    case ttsRate
    case candidate
    case sdp
    case status
    case controllerUserId
    case code
    case message
}

private struct SharedReadingWireHeader: Decodable {
    let v: Int
    let t: String
}

private struct SharedReadingWireError: Decodable {
    let code: String
    let message: String?
}

private struct SharedReadingWireSyncEnvelope: Decodable {
    let sessionId: String?
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let connectionGeneration: SharedReadingConnectionGeneration
    let frame: SharedReadingSyncFrame
}

private struct OutgoingEnvelope: Encodable {
    let message: SharedReadingSignalingOutgoingMessage

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SharedReadingWireCodingKeys.self)
        try container.encode(1, forKey: .v)

        switch message {
        case .sessionStart(let fence):
            try container.encode("session.start", forKey: .t)
            try encode(fence: fence, into: &container)
        case .leave(let fence):
            try container.encode("leave", forKey: .t)
            try encode(fence: fence, into: &container)
        case .end(let fence):
            try container.encode("session.end", forKey: .t)
            try encode(fence: fence, into: &container)
        case .speakerRequest(let fence, let requestId):
            try container.encode("speaker.request", forKey: .t)
            try encode(fence: fence, into: &container)
            try container.encode(requestId, forKey: .requestId)
        case .speakerRelease(let fence):
            try container.encode("speaker.release", forKey: .t)
            try encode(fence: fence, into: &container)
        case .syncFrame(let frame):
            try container.encode("sync.frame", forKey: .t)
            try container.encode(try SharedReadingWireSnapshot(frame: frame), forKey: .frame)
        case .sdpOffer(let toUserId, let sdp):
            try container.encode("sdp.offer", forKey: .t)
            try container.encode(toUserId, forKey: .to)
            try container.encode(sdp, forKey: .sdp)
        case .sdpAnswer(let toUserId, let sdp):
            try container.encode("sdp.answer", forKey: .t)
            try container.encode(toUserId, forKey: .to)
            try container.encode(sdp, forKey: .sdp)
        case .ice(let toUserId, let candidate):
            try container.encode("ice", forKey: .t)
            try container.encode(toUserId, forKey: .to)
            try container.encode(candidate, forKey: .candidate)
        }
    }

    private func encode(
        fence: SharedReadingSignalFence,
        into container: inout KeyedEncodingContainer<SharedReadingWireCodingKeys>
    ) throws {
        try container.encode(fence.roomEpoch, forKey: .roomEpoch)
        try container.encode(fence.controllerGeneration, forKey: .controllerGeneration)
        try container.encode(fence.connectionGeneration, forKey: .connectionGeneration)
    }
}

private struct SharedReadingWireSnapshot: Encodable {
    let v = 1
    let t = "snapshot"
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let sequence: Int64
    let bookId: String
    let contentHash: String
    let format: SharedReadingBookFormat
    let position: SharedReadingWirePosition
    let isPlaying: Bool
    let ttsRate: Double
    let source = "controller"

    init(frame: SharedReadingSyncFrame) throws {
        roomEpoch = frame.roomEpoch
        controllerGeneration = frame.controllerGeneration
        sequence = frame.sequence
        bookId = frame.bookId
        contentHash = frame.contentHash
        format = frame.format
        position = try SharedReadingWirePosition(frame: frame)
        isPlaying = frame.isPlaying
        ttsRate = frame.ttsRate
    }
}

private struct SharedReadingWirePosition: Encodable {
    static let maxLocatorBytes = 8 * 1024
    let format: SharedReadingBookFormat
    let cfi: String?
    let page: Int?
    let offsetY: Double?
    let readiumLocator: String
    let positionSource: ReaderPositionLocator.Source

    init(frame: SharedReadingSyncFrame) throws {
        format = frame.format
        guard let position = try? ReaderPositionLocator.decode(jsonString: frame.position),
              !position.readiumLocator.isEmpty,
              position.readiumLocator.utf8.count <= Self.maxLocatorBytes,
              let native = position.toReadiumLocator(), !native.href.string.isEmpty,
              let data = position.readiumLocator.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = object["locations"] as? [String: Any] else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "The reader position cannot be shared.")
        }
        readiumLocator = position.readiumLocator
        positionSource = position.source
        switch frame.format {
        case .epub:
            let other = locations["otherLocations"] as? [String: Any]
            guard let partialCFI = (other?["partialCfi"] ?? other?["cfi"]) as? String,
                  !partialCFI.isEmpty else {
                throw SharedReadingError.from(code: .serviceUnavailable, message: "The EPUB position cannot be shared.")
            }
            cfi = partialCFI
            page = nil
            offsetY = nil
        case .pdf:
            guard let pageNumber = locations["position"] as? Int, pageNumber >= 0 else {
                throw SharedReadingError.from(code: .serviceUnavailable, message: "The PDF page cannot be shared.")
            }
            let progression = locations["progression"] as? Double ?? 0
            guard progression.isFinite else {
                throw SharedReadingError.from(code: .serviceUnavailable, message: "The PDF position cannot be shared.")
            }
            cfi = nil
            page = pageNumber
            offsetY = min(1, max(0, progression))
        }
    }
}

private extension SharedReadingErrorCode {
    init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }
}

private extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private let sharedReadingSignalingDefaultBackoff: @Sendable (Int) -> Duration = { attempt in
    let exponent = max(0, attempt - 1)
    let seconds = min(SharedReadingSignalingClient.maxReconnectDelaySeconds, pow(2.0, Double(exponent)))
    return .seconds(seconds)
}

/// AsyncStream is single-consumer. The coordinator and peer mesh both need
/// every signaling event, so the WebSocket client fans events out to an
/// independent stream for each subscriber.
final class SharedReadingSignalingEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SharedReadingSignalingEvent>.Continuation] = [:]
    private var isFinished = false

    func subscribe() -> AsyncStream<SharedReadingSignalingEvent> {
        let id = UUID()
        var continuation: AsyncStream<SharedReadingSignalingEvent>.Continuation!
        let stream = AsyncStream<SharedReadingSignalingEvent> { continuation = $0 }
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func yield(_ event: SharedReadingSignalingEvent) {
        lock.lock()
        let subscribers = Array(continuations.values)
        lock.unlock()
        for continuation in subscribers { continuation.yield(event) }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let subscribers = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in subscribers { continuation.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

actor SharedReadingSignalingClient: SharedReadingSignalingTransport {
    static let maxFrameBytes = 64 * 1024
    static let maxReconnectDelaySeconds: Double = 5 * 60
    private static let maxReconnectAttempts = 6

    private let urlSession: URLSession
    private let backoff: @Sendable (Int) -> Duration

    nonisolated let eventHub = SharedReadingSignalingEventHub()
    nonisolated var events: AsyncStream<SharedReadingSignalingEvent> {
        eventHub.subscribe()
    }

    private var currentAdmission: SharedReadingAdmission?
    private var bearerToken: String?
    private var currentTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    private var reconnectAttempt = 0
    private var pendingReconnectDecision: SharedReadingReconnectDecision = .refreshAdmission
    private var hasAuthoritativeSessionState = false
    private var isDisconnecting = false
    private var isTerminal = false
    private var refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?
    private var refreshBearerToken: (@Sendable () async throws -> String)?
    private var currentHandshakeCorrelationID: String?
    private var latestHandshakeFailure: SharedReadingError?
    private var latestAdmissionRefreshFailure: SharedReadingError?
    private var didRefreshBearerForJoin = false

    init(
        urlSession: URLSession = .shared,
        backoff: @escaping @Sendable (Int) -> Duration = sharedReadingSignalingDefaultBackoff
    ) {
        self.urlSession = urlSession
        self.backoff = backoff

    }

    func connect(
        admission: SharedReadingAdmission,
        bearerToken: String,
        refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)? = nil,
        refreshBearerToken: (@Sendable () async throws -> String)? = nil
    ) async throws {
        guard !bearerToken.isEmpty else {
            throw SharedReadingError.from(code: .authRequired)
        }
        guard !isTerminal else {
            throw SharedReadingError.from(code: .sessionEnded)
        }

        currentAdmission = admission
        self.bearerToken = bearerToken
        self.refreshAdmission = refreshAdmission
        self.refreshBearerToken = refreshBearerToken
        isDisconnecting = false
        reconnectAttempt = 0
        pendingReconnectDecision = .refreshAdmission
        hasAuthoritativeSessionState = false
        latestHandshakeFailure = nil
        latestAdmissionRefreshFailure = nil
        didRefreshBearerForJoin = false

        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil

        Log.sharedReading(.socket, context: .init(outcome: .started, roomEpoch: admission.roomEpoch.rawValue, connectionGeneration: admission.connectionGeneration.rawValue))
        await open()
    }

    func disconnect() async {
        guard !isTerminal else { return }
        isDisconnecting = true
        isTerminal = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
        hasAuthoritativeSessionState = false
        Log.sharedReading(.socket, context: .init(outcome: .disconnected))
        eventHub.finish()
    }

    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws {
        guard !isTerminal else {
            throw SharedReadingError.from(code: .sessionEnded)
        }
        guard hasAuthoritativeSessionState, let currentTask, currentTask.state == .running else {
            throw SharedReadingError(
                code: .signalingDegraded,
                message: "Shared reading signaling is not connected.",
                retryable: true,
                action: .retry,
                correlationId: currentHandshakeCorrelationID,
                stage: "websocket.send",
                diagnostic: "authoritative_state_not_received"
            )
        }

        let data = try message.encoded(maxFrameBytes: Self.maxFrameBytes)
        do {
            try await currentTask.send(.data(data))
        } catch let error as NSError {
            throw SharedReadingError(
                code: .signalingDegraded,
                message: SharedReadingError.from(code: .signalingDegraded).message,
                retryable: true,
                action: .retry,
                correlationId: currentHandshakeCorrelationID,
                stage: "websocket.send",
                diagnostic: "send_failed",
                localSocketCode: error.code
            )
        }
    }

    private func open() async {
        guard !isTerminal, !isDisconnecting else { return }
        guard let admission = currentAdmission, let bearerToken else { return }

        generation += 1
        let currentGeneration = generation

        let protocols = [
            "rishi.sharing.v1",
            "jwt.\(Data(bearerToken.utf8).base64URLString())",
            "admission.\(admission.admissionTicket)",
        ]
        let correlationID = UUID().uuidString
        var request = URLRequest(url: admission.websocketURL)
        request.setValue(correlationID, forHTTPHeaderField: "X-Rishi-Correlation-ID")
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        currentHandshakeCorrelationID = correlationID
        let task = urlSession.webSocketTask(with: request)
        currentTask = task
        task.resume()
        hasAuthoritativeSessionState = false
        Log.sharedReading(.socket, context: .init(outcome: .started, attempt: reconnectAttempt, roomEpoch: admission.roomEpoch.rawValue, connectionGeneration: admission.connectionGeneration.rawValue))
        receiveTask?.cancel()
        receiveTask = Task { [weak self, task] in
            await self?.receiveLoop(task, generation: currentGeneration)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled, !isDisconnecting, !isTerminal {
            do {
                let message = try await task.receive()
                await handle(message, generation: generation)
            } catch {
                guard !Task.isCancelled, generation == self.generation, !isDisconnecting, !isTerminal else { break }
                let nsError = error as NSError
                let response = task.response as? HTTPURLResponse
                let failure: SharedReadingError
                if response?.statusCode == 101 {
                    failure = SharedReadingError(
                        code: .serviceUnavailable,
                        message: SharedReadingError.from(code: .serviceUnavailable).message,
                        retryable: true,
                        action: .retry,
                        correlationId: currentHandshakeCorrelationID,
                        stage: "websocket.receive",
                        localSocketCode: nsError.code
                    )
                    latestHandshakeFailure = failure
                    eventHub.yield(.error(failure))
                } else {
                    failure = handshakeFailure(response: response, localErrorCode: nsError.code)
                    latestHandshakeFailure = failure
                    eventHub.yield(.error(failure))
                    pendingReconnectDecision = reconnectDecision(forHandshakeFailure: failure)
                }
                Log.sharedReading(.socket, level: .error, context: .init(
                    outcome: .failed, correlationID: failure.correlationId,
                    statusCode: failure.httpStatus,
                    attempt: reconnectAttempt,
                    roomEpoch: currentAdmission?.roomEpoch.rawValue,
                    connectionGeneration: currentAdmission?.connectionGeneration.rawValue,
                    errorCode: failure.code.rawValue,
                    diagnostic: failure.diagnostic,
                    stage: failure.stage,
                    localSocketCode: failure.localSocketCode
                ))
                break
            }
        }
        await handleDisconnect(generation: generation)
    }

    private func handshakeFailure(response: HTTPURLResponse?, localErrorCode: Int) -> SharedReadingError {
        let rawCode = response?.value(forHTTPHeaderField: "X-Rishi-Error-Code")
        let workerCode = rawCode.flatMap(SharedReadingErrorCode.init(rawValue:))
        let code: SharedReadingErrorCode
        if let workerCode {
            code = workerCode
        } else {
            switch response?.statusCode {
            case 401: code = .authRequired
            case 403: code = .forbidden
            case 404, 410: code = .sessionEnded
            case 409: code = .roomFull
            default: code = .serviceUnavailable
            }
        }
        let fallback = SharedReadingError.from(code: code)
        return SharedReadingError(
            code: code,
            message: fallback.message,
            retryable: fallback.retryable,
            action: fallback.action,
            correlationId: Self.safeCorrelationID(response?.value(forHTTPHeaderField: "X-Rishi-Correlation-ID")) ?? currentHandshakeCorrelationID,
            stage: response?.value(forHTTPHeaderField: "X-Rishi-Error-Stage") ?? "websocket.handshake",
            httpStatus: response?.statusCode,
            diagnostic: workerCode == nil ? rawCode : nil,
            localSocketCode: localErrorCode
        )
    }

    private func reconnectDecision(forHandshakeFailure error: SharedReadingError) -> SharedReadingReconnectDecision {
        switch error.code {
        case .authRequired:
            return didRefreshBearerForJoin ? .stop(error.code) : .refreshBearer
        case .admissionRequired, .admissionTicketExpired, .admissionTicketMismatch,
                .admissionTicketStale, .invalidAdmission, .reconnectExpired:
            return .refreshAdmission
        case .sessionEnded, .sessionNotFound, .removedFromSession, .forbidden, .accountDeleted, .accountDeletionInProgress,
                .roomFull, .sessionLinkInvalid, .onboardingRequired,
                .malformedWebSocketRequest, .webSocketUpgradeRequired:
            return .stop(error.code)
        default:
            return .refreshAdmission
        }
    }

    private static func safeCorrelationID(_ value: String?) -> String? {
        guard let value, (1...100).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) })
        else { return nil }
        return value
    }

    private static func withHandshakeContext(
        _ error: SharedReadingError,
        stage: String
    ) -> SharedReadingError {
        SharedReadingError(
            code: error.code,
            message: error.message,
            retryable: error.retryable,
            action: error.action,
            correlationId: error.correlationId,
            stage: error.stage ?? stage,
            httpStatus: error.httpStatus,
            diagnostic: error.diagnostic,
            localSocketCode: error.localSocketCode
        )
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, generation: Int) async {
        guard generation == self.generation, !isDisconnecting, !isTerminal else { return }

        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        guard data.count <= Self.maxFrameBytes else {
            eventHub.yield(.error(SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading frame exceeded the 64 KiB limit.")))
            return
        }

        do {
            let event = try decodeEvent(from: data)
            Log.sharedReading(.signalingEvent, context: .init(outcome: .accepted))
            eventHub.yield(event)
            if case .error(let error) = event {
                pendingReconnectDecision = SharedReadingReconnectDecision.forError(error.code)
            }
            if shouldTerminate(after: event) {
                terminateAfterTerminalEvent()
            }
        } catch let error as SharedReadingError {
            Log.sharedReading(.signalingEvent, level: .error, context: .init(outcome: .rejected, errorCode: error.code.rawValue))
            eventHub.yield(.error(error))
        } catch {
            Log.sharedReading(.signalingEvent, level: .error, context: .init(outcome: .rejected, errorCode: "INVALID_PAYLOAD"))
            eventHub.yield(.error(SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading signaling payload could not be decoded.")))
        }
    }

    private func decodeEvent(from data: Data) throws -> SharedReadingSignalingEvent {
        let header = try JSONDecoder().decode(SharedReadingWireHeader.self, from: data)
        guard header.v == 1 else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading signaling version is not supported.")
        }

        switch header.t {
        case "session.state":
            return .sessionState(try JSONDecoder().decode(SharedReadingSessionStateEvent.self, from: data))
        case "sync.frame":
            let envelope = try JSONDecoder().decode(SharedReadingWireSyncEnvelope.self, from: data)
            let frame = envelope.frame
            return .syncFrame(SharedReadingSyncFrame(
                sessionId: envelope.sessionId ?? frame.sessionId,
                roomEpoch: envelope.roomEpoch,
                controllerGeneration: envelope.controllerGeneration,
                connectionGeneration: envelope.connectionGeneration,
                sequence: frame.sequence,
                bookId: frame.bookId,
                contentHash: frame.contentHash,
                format: frame.format,
                position: frame.position,
                isPlaying: frame.isPlaying,
                ttsRate: frame.ttsRate
            ))
        case "sync.absent":
            return .syncAbsent(try JSONDecoder().decode(SharedReadingSyncAbsentEvent.self, from: data))
        case "controller.transfer":
            return .controllerTransfer(try JSONDecoder().decode(SharedReadingControllerTransferEvent.self, from: data))
        case "participant.remove":
            return .participantRemove(try JSONDecoder().decode(SharedReadingParticipantRemoveEvent.self, from: data))
        case "participant.roster":
            return .participantRoster(try JSONDecoder().decode(SharedReadingParticipantRosterEvent.self, from: data))
        case "speaker.granted":
            return .speakerGranted(try JSONDecoder().decode(SharedReadingSpeakerGrantedEvent.self, from: data))
        case "speaker.released":
            return .speakerReleased(try JSONDecoder().decode(SharedReadingSpeakerReleasedEvent.self, from: data))
        case "session.ended":
            return .sessionEnded(try JSONDecoder().decode(SharedReadingSessionEndedEvent.self, from: data))
        case "sdp.offer":
            return .sdpOffer(try JSONDecoder().decode(SharedReadingSDPEvent.self, from: data))
        case "sdp.answer":
            return .sdpAnswer(try JSONDecoder().decode(SharedReadingSDPEvent.self, from: data))
        case "ice":
            return .ice(try JSONDecoder().decode(SharedReadingICEEvent.self, from: data))
        case "error":
            let wireError = try JSONDecoder().decode(SharedReadingWireError.self, from: data)
            guard let code = SharedReadingErrorCode(wireValue: wireError.code) else {
                return .error(SharedReadingError.from(code: .serviceUnavailable, message: wireError.message))
            }
            return .error(SharedReadingError.from(code: code, message: wireError.message))
        default:
            throw SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading signaling event '\(header.t)' is not supported.")
        }
    }

    private func shouldTerminate(after event: SharedReadingSignalingEvent) -> Bool {
        Self.shouldTerminateImmediately(after: event)
    }

    static func shouldTerminateImmediately(after event: SharedReadingSignalingEvent) -> Bool {
        switch event {
        case .error(let error):
            return error.code == .sessionEnded || error.code == .removedFromSession || error.code == .accountDeleted || error.code == .accountDeletionInProgress
        case .sessionState, .sessionEnded, .syncFrame, .syncAbsent, .controllerTransfer, .participantRemove, .participantRoster, .speakerGranted, .speakerReleased, .sdpOffer, .sdpAnswer, .ice:
            return false
        }
    }

    private func terminateAfterTerminalEvent() {
        guard !isTerminal else { return }
        isTerminal = true
        isDisconnecting = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
        eventHub.finish()
    }

    private func handleDisconnect(generation: Int) async {
        guard generation == self.generation else { return }
        let hadState = hasAuthoritativeSessionState
        hasAuthoritativeSessionState = false
        currentTask = nil
        receiveTask = nil
        guard !isDisconnecting, !isTerminal else { return }
        Log.sharedReading(.socket, level: .warning, context: .init(
            outcome: .disconnected, attempt: reconnectAttempt,
            connectionGeneration: currentAdmission?.connectionGeneration.rawValue,
            errorCode: hadState ? "AFTER_STATE" : "BEFORE_STATE"
        ))
        scheduleReconnect(pendingReconnectDecision)
    }

    private func scheduleReconnect(_ decision: SharedReadingReconnectDecision) {
        guard reconnectTask == nil else { return }
        if case .stop(let code) = decision {
            // Keep the actual handshake response when a terminal decision is
            // made (notably after a refreshed bearer is rejected as well).
            // Rebuilding from only the error code drops the Worker's stage,
            // status, and correlation ID; the coordinator then mistakes the
            // stream close for a generic SIGNALING_DEGRADED failure.
            let failure = latestHandshakeFailure.flatMap { $0.code == code ? $0 : nil }
                ?? .from(code: code)
            eventHub.yield(.error(failure))
            terminateAfterTerminalEvent()
            return
        }
        reconnectAttempt += 1
        if reconnectAttempt > Self.maxReconnectAttempts {
            let failure = latestAdmissionRefreshFailure ?? latestHandshakeFailure ?? SharedReadingError(
                code: .signalingDegraded,
                message: "Could not reconnect to the reading session. Leave and try joining again.",
                retryable: true,
                action: .retry,
                correlationId: currentHandshakeCorrelationID,
                stage: "websocket.reconnect",
                diagnostic: "retry_limit_exceeded"
            )
            eventHub.yield(.error(failure))
            terminateAfterTerminalEvent()
            return
        }
        let attempt = reconnectAttempt
        Log.sharedReading(.reconnect, level: .warning, context: .init(outcome: .retrying, attempt: attempt))
        let delay: Duration
        if case .retry(let requestedDelay) = decision, requestedDelay > .zero {
            delay = requestedDelay
        } else {
            delay = backoff(attempt)
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnect(decision: decision, attempt: attempt)
        }
    }

    private func reconnect(decision: SharedReadingReconnectDecision, attempt: Int) async {
        reconnectTask = nil
        guard !isDisconnecting, !isTerminal else { return }

        switch decision {
        case .refreshBearer:
            guard let refreshBearerToken else {
                eventHub.yield(.error(latestHandshakeFailure ?? .from(code: .authRequired)))
                terminateAfterTerminalEvent()
                return
            }
            do {
                Log.sharedReading(.authenticationRefresh, context: .init(outcome: .started, attempt: attempt))
                bearerToken = try await refreshBearerToken()
                didRefreshBearerForJoin = true
                Log.sharedReading(.authenticationRefresh, context: .init(outcome: .completed, attempt: attempt))
            } catch let error as SharedReadingError {
                Log.sharedReading(.authenticationRefresh, level: .error, context: .init(outcome: .failed, correlationID: error.correlationId, attempt: attempt, errorCode: error.code.rawValue))
                eventHub.yield(.error(Self.withHandshakeContext(error, stage: "websocket.authentication_refresh")))
                terminateAfterTerminalEvent()
                return
            } catch {
                Log.sharedReading(.authenticationRefresh, level: .error, context: .init(outcome: .failed, attempt: attempt, errorCode: "UNKNOWN"))
                eventHub.yield(.error(SharedReadingError(
                    code: .serviceUnavailable,
                    message: SharedReadingError.from(code: .serviceUnavailable).message,
                    retryable: true,
                    action: .retry,
                    stage: "websocket.authentication_refresh",
                    diagnostic: "UNKNOWN"
                )))
                terminateAfterTerminalEvent()
                return
            }
        case .stop(let code):
            eventHub.yield(.error(latestHandshakeFailure ?? .from(code: code)))
            terminateAfterTerminalEvent()
            return
        case .retry, .refreshAdmission:
            break
        }
        // Admission tickets are single use, including when the WebSocket
        // handshake never produced an authoritative state. Never reopen with
        // the ticket that was passed to the previous URLSessionWebSocketTask.
        guard let refreshAdmission else {
            let failure = SharedReadingError(
                code: .reconnectExpired,
                message: SharedReadingError.from(code: .reconnectExpired).message,
                retryable: true,
                action: .retry,
                correlationId: currentHandshakeCorrelationID,
                stage: "websocket.admission_refresh",
                diagnostic: "refresh_handler_missing"
            )
            latestAdmissionRefreshFailure = failure
            eventHub.yield(.error(failure))
            terminateAfterTerminalEvent()
            return
        }
        do {
            let admission = try await refreshAdmission()
            guard !Task.isCancelled, !isDisconnecting, !isTerminal else { return }
            currentAdmission = admission
            latestAdmissionRefreshFailure = nil
        } catch let error as SharedReadingError {
            guard !Task.isCancelled, !isDisconnecting, !isTerminal else { return }
            let failure = Self.withHandshakeContext(error, stage: "websocket.admission_refresh")
            latestAdmissionRefreshFailure = failure
            Log.sharedReading(.reconnect, level: .error, context: .init(
                outcome: .failed,
                correlationID: failure.correlationId,
                statusCode: failure.httpStatus,
                attempt: attempt,
                errorCode: failure.code.rawValue,
                diagnostic: failure.diagnostic,
                stage: failure.stage,
                localSocketCode: failure.localSocketCode
            ))
            if failure.retryable { scheduleReconnect(.refreshAdmission) }
            else { eventHub.yield(.error(failure)); terminateAfterTerminalEvent() }
            return
        } catch {
            guard !Task.isCancelled, !isDisconnecting, !isTerminal else { return }
            let failure = SharedReadingError(
                code: .serviceUnavailable,
                message: SharedReadingError.from(code: .serviceUnavailable).message,
                retryable: true,
                action: .retry,
                correlationId: nil,
                stage: "websocket.admission_refresh",
                diagnostic: "unknown_error"
            )
            latestAdmissionRefreshFailure = failure
            Log.sharedReading(.reconnect, level: .error, context: .init(
                outcome: .failed,
                correlationID: failure.correlationId,
                statusCode: failure.httpStatus,
                attempt: attempt,
                errorCode: failure.code.rawValue,
                diagnostic: failure.diagnostic,
                stage: failure.stage
            ))
            scheduleReconnect(.refreshAdmission)
            return
        }
        await open()
    }

    func confirmAuthoritativeSessionState(_ state: SharedReadingSessionStateEvent) async {
        guard !isTerminal, state.status != .ended,
              let admission = currentAdmission,
              state.roomEpoch == admission.roomEpoch,
              state.connectionGeneration == admission.connectionGeneration else { return }
        hasAuthoritativeSessionState = true
        reconnectAttempt = 0
        latestAdmissionRefreshFailure = nil
        pendingReconnectDecision = .refreshAdmission
        latestHandshakeFailure = nil
        didRefreshBearerForJoin = false
        Log.sharedReading(.socket, context: .init(outcome: .connected, roomEpoch: state.roomEpoch.rawValue, connectionGeneration: state.connectionGeneration.rawValue))
    }

    func latestHandshakeCorrelationID() -> String? { currentHandshakeCorrelationID }

}

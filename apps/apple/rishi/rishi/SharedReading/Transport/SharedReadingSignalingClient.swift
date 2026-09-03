import Foundation

protocol SharedReadingSignalingTransport: Sendable {
    var events: AsyncStream<SharedReadingSignalingEvent> { get }

    func connect(admission: SharedReadingAdmission, bearerToken: String, refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?) async throws
    func disconnect() async
    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws
}

enum SharedReadingSignalingEvent: Sendable, Equatable {
    case sessionState(SharedReadingSessionStateEvent)
    case syncFrame(SharedReadingSyncFrame)
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

struct SharedReadingSignalFence: Codable, Sendable, Equatable {
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
}

struct SharedReadingSessionStateEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let status: SharedReadingSessionStatus
    let controllerUserId: String
}

struct SharedReadingSyncFrame: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
        roomEpoch: Int,
        controllerGeneration: Int,
        connectionGeneration: Int,
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
        roomEpoch = try c.decodeIfPresent(Int.self, forKey: .roomEpoch) ?? 0
        controllerGeneration = try c.decodeIfPresent(Int.self, forKey: .controllerGeneration) ?? 0
        connectionGeneration = try c.decodeIfPresent(Int.self, forKey: .connectionGeneration) ?? 0
        sequence = try c.decode(Int64.self, forKey: .sequence)
        bookId = try c.decode(String.self, forKey: .bookId)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        format = try c.decodeIfPresent(SharedReadingBookFormat.self, forKey: .format) ?? .epub
        if let text = try? c.decode(String.self, forKey: .position) {
            position = text
        } else {
            let object = try c.decode(SharedReadingWirePositionPayload.self, forKey: .position)
            position = Self.locatorJSONString(from: object)
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

    private static func locatorJSONString(from payload: SharedReadingWirePositionPayload) -> String {
        let locations: [String: Any]
        switch payload.format {
        case .epub:
            locations = ["otherLocations": ["cfi": payload.cfi ?? ""]]
        case .pdf:
            locations = [
                "position": payload.page ?? 0,
                "progression": payload.offsetY ?? 0,
            ]
        }
        let object: [String: Any] = [
            "href": "",
            "type": payload.format == .pdf ? "application/pdf" : "application/xhtml+xml",
            "locations": locations,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

private struct SharedReadingWirePositionPayload: Codable {
    let format: SharedReadingBookFormat
    let cfi: String?
    let page: Int?
    let offsetY: Double?
}

struct SharedReadingControllerTransferEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let userId: String
    let reason: SharedReadingParticipantRemovalReason
}

struct SharedReadingParticipantRosterEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let rosterGeneration: Int
    let participants: [SharedReadingParticipant]
}

struct SharedReadingSpeakerGrantedEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let requestId: String?
    let speakerUserId: String
}

struct SharedReadingSpeakerReleasedEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
    let reason: SharedReadingSessionEndedReason
}

struct SharedReadingSDPEvent: Codable, Sendable, Equatable {
    let sessionId: String?
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
        guard data.count <= maxFrameBytes else {
            throw SharedReadingError.from(code: .serviceUnavailable, message: "Shared reading frame exceeded the 64 KiB limit.")
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
    let roomEpoch: Int
    let controllerGeneration: Int
    let connectionGeneration: Int
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
            try container.encode(SharedReadingWireSnapshot(frame: frame), forKey: .frame)
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
    let roomEpoch: Int
    let controllerGeneration: Int
    let sequence: Int64
    let bookId: String
    let contentHash: String
    let format: SharedReadingBookFormat
    let position: SharedReadingWirePosition
    let isPlaying: Bool
    let ttsRate: Double
    let source = "controller"

    init(frame: SharedReadingSyncFrame) {
        roomEpoch = frame.roomEpoch
        controllerGeneration = frame.controllerGeneration
        sequence = frame.sequence
        bookId = frame.bookId
        contentHash = frame.contentHash
        format = frame.format
        position = SharedReadingWirePosition(frame: frame)
        isPlaying = frame.isPlaying
        ttsRate = frame.ttsRate
    }
}

private struct SharedReadingWirePosition: Encodable {
    let format: SharedReadingBookFormat
    let cfi: String?
    let page: Int?
    let offsetY: Double?

    init(frame: SharedReadingSyncFrame) {
        format = frame.format
        cfi = frame.format == .epub ? Self.epubCFI(from: frame.position) : nil
        page = frame.format == .pdf ? Self.pdfPage(from: frame.position) : nil
        offsetY = frame.format == .pdf ? Self.pdfOffsetY(from: frame.position) : nil
    }

    private static func epubCFI(from position: String) -> String {
        guard let locator = try? ReaderPositionLocator.decode(jsonString: position),
              let data = locator.readiumLocator.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = object["locations"] as? [String: Any],
              let otherLocations = locations["otherLocations"] as? [String: Any],
              let cfi = otherLocations["cfi"] as? String,
              !cfi.isEmpty else { return position }
        return cfi
    }

    private static func pdfPage(from position: String) -> Int {
        guard let locator = try? ReaderPositionLocator.decode(jsonString: position),
              let data = locator.readiumLocator.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = object["locations"] as? [String: Any],
              let page = locations["position"] as? Int else { return 0 }
        return max(0, page)
    }

    private static func pdfOffsetY(from position: String) -> Double {
        guard let locator = try? ReaderPositionLocator.decode(jsonString: position),
              let data = locator.readiumLocator.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = object["locations"] as? [String: Any],
              let progression = locations["progression"] as? Double else { return 0 }
        return max(0, progression)
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
    private var isDisconnecting = false
    private var isTerminal = false
    private var refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?

    init(
        urlSession: URLSession = .shared,
        backoff: @escaping @Sendable (Int) -> Duration = sharedReadingSignalingDefaultBackoff
    ) {
        self.urlSession = urlSession
        self.backoff = backoff

    }

    func connect(admission: SharedReadingAdmission, bearerToken: String, refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)? = nil) async throws {
        guard !bearerToken.isEmpty else {
            throw SharedReadingError.from(code: .authRequired)
        }
        guard !isTerminal else {
            throw SharedReadingError.from(code: .sessionEnded)
        }

        currentAdmission = admission
        self.bearerToken = bearerToken
        self.refreshAdmission = refreshAdmission
        isDisconnecting = false
        reconnectAttempt = 0

        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil

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
        eventHub.finish()
    }

    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws {
        guard !isTerminal else {
            throw SharedReadingError.from(code: .sessionEnded)
        }
        guard let currentTask, currentTask.state == .running else {
            throw SharedReadingError.from(code: .signalingDegraded, message: "Shared reading signaling is not connected.")
        }

        let data = try message.encoded(maxFrameBytes: Self.maxFrameBytes)
        do {
            try await currentTask.send(.data(data))
        } catch {
            throw SharedReadingError.from(code: .signalingDegraded)
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
        let task = urlSession.webSocketTask(with: admission.websocketURL, protocols: protocols)
        currentTask = task
        task.resume()
        reconnectAttempt = 0

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
                break
            }
        }
        await handleDisconnect(generation: generation)
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
            eventHub.yield(event)
            reconnectAttempt = 0
            if shouldTerminate(after: event) {
                terminateAfterTerminalEvent()
            }
        } catch let error as SharedReadingError {
            eventHub.yield(.error(error))
        } catch {
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
        switch event {
        case .sessionEnded:
            return true
        case .sessionState(let state):
            return state.status == .ended
        case .error(let error):
            return error.code == .sessionEnded || error.code == .removedFromSession
        case .syncFrame, .controllerTransfer, .participantRemove, .participantRoster, .speakerGranted, .speakerReleased, .sdpOffer, .sdpAnswer, .ice:
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
        currentTask = nil
        receiveTask = nil
        guard !isDisconnecting, !isTerminal else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = backoff(attempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if let self, let refresh = await self.refreshAdmission {
                do { await self.setAdmission(try await refresh()) }
                catch let error as SharedReadingError { self.eventHub.yield(.error(error)); return }
                catch { self.eventHub.yield(.error(.from(code: .serviceUnavailable))); return }
            }
            await self?.open()
        }
    }

    private func setAdmission(_ admission: SharedReadingAdmission) { currentAdmission = admission }

}

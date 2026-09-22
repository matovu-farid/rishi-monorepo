import Foundation

protocol SharedReadingAPIClient: Sendable {
    func create(bookId: String, idempotencyKey: String) async throws -> SharedReadingCreateResponse
    func sendEmail(sessionId: String, recipients: [String], idempotencyKey: String) async throws -> SharedReadingEmailResponse
    func redeem(token: String) async throws -> SharedReadingRedeemResponse
    func markBookReady(sessionId: String, token: String, contentHash: String) async throws -> SharedReadingAdmission
    func rejoin(sessionId: String, contentHash: String) async throws -> SharedReadingAdmission
    func start(sessionId: String) async throws -> SharedReadingSessionControlResponse
    func end(sessionId: String) async throws -> SharedReadingSessionControlResponse
    func activeSessions() async throws -> SharedReadingActiveResponse
    func status(sessionId: String) async throws -> SharedReadingRoomStatus
    func leave(sessionId: String, deliberate: Bool) async throws -> SharedReadingSessionControlResponse
    func transferController(sessionId: String, targetUserId: String) async throws -> SharedReadingSessionControlResponse
    func removeParticipant(sessionId: String, participantUserId: String) async throws -> SharedReadingSessionControlResponse
    func restoreParticipant(sessionId: String, participantUserId: String, contentHash: String) async throws -> SharedReadingRestoreResponse
    func endFromController(sessionId: String) async throws -> SharedReadingSessionControlResponse
    func turnCredentials(sessionId: String) async throws -> SharedReadingTurnCredentials
    func bearerToken() async throws -> String
    func refreshBearerToken() async throws -> String
}

struct SharedReadingEmailResponse: Codable, Sendable, Equatable {
    struct Delivery: Codable, Sendable, Equatable, Identifiable {
        let email: String
        let status: Status
        let errorCode: String?

        enum Status: String, Codable, Sendable, Equatable {
            case sent
            case failed
            case alreadySent = "already_sent"
        }

        var id: String { email }
    }

    let shareURL: URL
    let attempted: Int
    let sent: Int
    let failed: Int
    let results: [Delivery]
    let retryable: Bool
    let action: String
    let correlationId: String
}

struct SharedReadingSessionControlResponse: Codable, Sendable, Equatable {
    let sessionId: String
    let status: SharedReadingSessionStatus
    let roomEpoch: SharedReadingRoomEpoch
    let controllerGeneration: SharedReadingControllerGeneration
    let controllerUserId: String
}

struct SharedReadingRestoreResponse: Codable, Sendable, Equatable {
    let admissionTicket: String
    let status: SharedReadingSessionStatus
    let roomEpoch: SharedReadingRoomEpoch
}

actor SharedReadingAPI: SharedReadingAPIClient {
    private static let routePrefix = "/api/v1/reading-sessions"
    private struct EmailRequest: Encodable {
        let recipients: [String]
        let idempotencyKey: String
    }
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any TokenProvider
    private let refreshAuthentication: (@Sendable () async throws -> Void)?
    private let requestTimeout: TimeInterval
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any TokenProvider,
        refreshAuthentication: (@Sendable () async throws -> Void)? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.refreshAuthentication = refreshAuthentication
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func create(bookId: String, idempotencyKey: String) async throws -> SharedReadingCreateResponse {
        try await send(path: "\(Self.routePrefix)", method: "POST", body: ["bookId": bookId, "idempotencyKey": idempotencyKey])
    }

    func sendEmail(sessionId: String, recipients: [String], idempotencyKey: String) async throws -> SharedReadingEmailResponse {
        try await send(
            path: "\(Self.routePrefix)/\(sessionId)/email",
            method: "POST",
            body: EmailRequest(recipients: recipients, idempotencyKey: idempotencyKey)
        )
    }

    func redeem(token: String) async throws -> SharedReadingRedeemResponse {
        try await send(path: "\(Self.routePrefix)/redeem", method: "POST", body: ["token": token])
    }

    func markBookReady(sessionId: String, token: String, contentHash: String) async throws -> SharedReadingAdmission {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/book-ready", method: "POST", body: ["token": token, "contentHash": contentHash])
    }

    func rejoin(sessionId: String, contentHash: String) async throws -> SharedReadingAdmission {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/rejoin", method: "POST", body: ["contentHash": contentHash])
    }

    func start(sessionId: String) async throws -> SharedReadingSessionControlResponse {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/start", method: "POST", body: EmptyBody())
    }

    func end(sessionId: String) async throws -> SharedReadingSessionControlResponse {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/end", method: "POST", body: EmptyBody())
    }

    func activeSessions() async throws -> SharedReadingActiveResponse {
        try await send(path: "\(Self.routePrefix)/active", method: "GET", body: Optional<EmptyBody>.none)
    }

    func status(sessionId: String) async throws -> SharedReadingRoomStatus {
        try await send(path: "\(Self.routePrefix)/\(sessionId)", method: "GET", body: Optional<EmptyBody>.none)
    }

    func leave(sessionId: String, deliberate: Bool) async throws -> SharedReadingSessionControlResponse {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/leave", method: "POST", body: ["deliberate": deliberate])
    }

    func transferController(sessionId: String, targetUserId: String) async throws -> SharedReadingSessionControlResponse {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/controller/transfer", method: "POST", body: ["targetUserId": targetUserId])
    }

    func removeParticipant(sessionId: String, participantUserId: String) async throws -> SharedReadingSessionControlResponse {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/participants/remove", method: "POST", body: ["participantUserId": participantUserId])
    }

    func restoreParticipant(sessionId: String, participantUserId: String, contentHash: String) async throws -> SharedReadingRestoreResponse {
        try await send(
            path: "\(Self.routePrefix)/\(sessionId)/participants/restore",
            method: "POST",
            body: ["participantUserId": participantUserId, "contentHash": contentHash]
        )
    }

    func endFromController(sessionId: String) async throws -> SharedReadingSessionControlResponse {
        try await end(sessionId: sessionId)
    }

    func turnCredentials(sessionId: String) async throws -> SharedReadingTurnCredentials {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/turn", method: "GET", body: Optional<EmptyBody>.none)
    }

    func bearerToken() async throws -> String {
        guard let token = await tokenProvider.token() else { throw SharedReadingError.from(code: .authRequired) }
        return token
    }

    func refreshBearerToken() async throws -> String {
        guard let refreshAuthentication else {
            throw SharedReadingError.from(code: .authRequired)
        }
        do {
            Log.sharedReading(.authenticationRefresh, context: .init(outcome: .started))
            try await refreshAuthentication()
            let token = try await bearerToken()
            Log.sharedReading(.authenticationRefresh, context: .init(outcome: .completed))
            return token
        } catch {
            Log.sharedReading(.authenticationRefresh, level: .error, context: .init(outcome: .failed, errorCode: Self.diagnosticErrorCode(error)))
            throw SharedReadingError.from(code: .authRequired)
        }
    }

    private struct EmptyBody: Encodable {}

    private func send<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: body,
            didRefreshAuthentication: false
        )
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        didRefreshAuthentication: Bool
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw SharedReadingError.from(code: .serviceUnavailable) }
        let requestID = UUID()
        let operation = Self.operation(for: path)
        let started = Date()
        Log.sharedReading(.apiRequest, context: .init(operation: operation, outcome: .started, operationID: requestID))
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = method
        request.setValue("v1", forHTTPHeaderField: "X-Rishi-API-Version")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Rishi-Request-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            if !didRefreshAuthentication, let refreshAuthentication {
                do {
                    try await refreshAuthentication()
                    return try await send(
                        path: path,
                        method: method,
                        body: body,
                        didRefreshAuthentication: true
                    )
                } catch {
                    Log.sharedReading(.authenticationRefresh, level: .error, context: .init(operation: operation, outcome: .failed, operationID: requestID, errorCode: Self.diagnosticErrorCode(error)))
                }
            }
            throw SharedReadingError.from(code: .authRequired)
        }
        if let body { request.httpBody = try encoder.encode(body) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SharedReadingError.from(code: .serviceUnavailable) }
            let correlationID = http.value(forHTTPHeaderField: "X-Rishi-Correlation-ID")
            Log.sharedReading(.apiResponse, context: .init(
                operation: operation,
                outcome: .completed,
                correlationID: correlationID,
                operationID: requestID,
                statusCode: http.statusCode,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000)
            ))
            if http.statusCode == 401, !didRefreshAuthentication, let refreshAuthentication {
                do {
                    try await refreshAuthentication()
                    return try await send(
                        path: path,
                        method: method,
                        body: body,
                        didRefreshAuthentication: true
                    )
                } catch {
                    Log.sharedReading(.authenticationRefresh, level: .error, context: .init(operation: operation, outcome: .failed, operationID: requestID, errorCode: Self.diagnosticErrorCode(error)))
                    throw SharedReadingError.from(code: .authRequired)
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                let error = decodeError(data, status: http.statusCode, path: path)
                Log.sharedReading(.apiFailure, level: .error, context: .init(
                    operation: operation,
                    outcome: .failed,
                    correlationID: error.correlationId ?? correlationID,
                    operationID: requestID,
                    statusCode: http.statusCode,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                    errorCode: error.code.rawValue
                ))
                throw error
            }
            do { return try decoder.decode(Response.self, from: data) }
            catch {
                Log.sharedReading(.apiFailure, level: .error, context: .init(
                    operation: operation,
                    outcome: .failed,
                    correlationID: correlationID,
                    operationID: requestID,
                    statusCode: http.statusCode,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                    errorCode: "INVALID_RESPONSE"
                ))
                throw SharedReadingError.from(code: .serviceUnavailable, message: "Rishi returned an invalid reading-session response.")
            }
        } catch let error as SharedReadingError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            let timeoutError = SharedReadingError.from(
                code: .serviceUnavailable,
                message: "The reading-session service did not respond in time. Try again."
            )
            Log.sharedReading(.apiFailure, level: .error, context: .init(
                operation: operation,
                outcome: .failed,
                operationID: requestID,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                errorCode: timeoutError.code.rawValue
            ))
            throw timeoutError
        } catch {
            Log.sharedReading(.apiFailure, level: .error, context: .init(
                operation: operation,
                outcome: .failed,
                operationID: requestID,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                errorCode: Self.diagnosticErrorCode(error)
            ))
            throw SharedReadingError.from(code: .serviceUnavailable)
        }
    }

    private func decodeError(_ data: Data, status: Int, path: String) -> SharedReadingError {
        struct Payload: Decodable {
            let code: String?
            let error: String?
            let retryable: Bool?
            let action: SharedReadingRecoveryAction?
            let correlationId: String?
        }
        if let payload = try? decoder.decode(Payload.self, from: data),
           let rawCode = payload.code,
           let code = SharedReadingErrorCode(rawValue: rawCode) {
            let fallback = SharedReadingError.from(code: code, message: payload.error)
            return SharedReadingError(
                code: code,
                message: payload.error ?? fallback.message,
                retryable: payload.retryable ?? fallback.retryable,
                action: payload.action ?? fallback.action,
                correlationId: payload.correlationId
            )
        }
        if status == 404, path == Self.routePrefix {
            return .from(
                code: .serviceUnavailable,
                message: "The reading-session service is not available yet."
            )
        }
        if status == 401 { return .from(code: .authRequired) }
        if status == 409 { return .from(code: .roomFull) }
        if status == 403 { return .from(code: .forbidden) }
        if status == 404 { return .from(code: .sessionLinkInvalid) }
        if status == 410 { return .from(code: .sessionEnded) }
        if status == 422 { return .from(code: .bookHashMismatch) }
        return .from(code: .serviceUnavailable)
    }

    private static func diagnosticErrorCode(_ error: Error) -> String {
        if let error = error as? SharedReadingError { return error.code.rawValue }
        if error is URLError { return "URL_ERROR" }
        return "UNKNOWN"
    }

    private static func operation(for path: String) -> SharedReadingDiagnosticContext.Operation {
        if path == routePrefix { return .create }
        if path.hasSuffix("/email") { return .email }
        if path.hasSuffix("/redeem") { return .redeem }
        if path.hasSuffix("/book-ready") { return .bookReady }
        if path.hasSuffix("/rejoin") { return .rejoin }
        if path.hasSuffix("/active") { return .active }
        if path.hasSuffix("/start") { return .start }
        if path.hasSuffix("/end") { return .end }
        if path.hasSuffix("/leave") { return .leave }
        if path.hasSuffix("/turn") { return .turn }
        if path.hasSuffix("/controller/transfer") { return .controllerTransfer }
        if path.hasSuffix("/participants/remove") { return .participantRemove }
        if path.hasSuffix("/participants/restore") { return .participantRestore }
        return .status
    }
}

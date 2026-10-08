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
    private enum Authentication: Sendable {
        case legacy(any TokenProvider, (@Sendable () async throws -> Void)?)
        case scoped(SessionCredentialAuthority, WorkerClient, CredentialRequestContext)
        case admittedCleanup(String)
    }
    private let authentication: Authentication
    /// The rejected socket bearer may predate a same-lease HTTP refresh.
    private var socketRejectionContext: CredentialRejectionContext?
    private let requestTimeout: TimeInterval
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    nonisolated func isBound(to authority: SessionCredentialAuthority,
                            context: CredentialRequestContext) -> Bool {
        guard case .normal(let expectedLease) = context,
              case .scoped(let owner, _, .normal(let capturedLease)) = authentication else { return false }
        return owner === authority && capturedLease == expectedLease
    }

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any TokenProvider,
        refreshAuthentication: (@Sendable () async throws -> Void)? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authentication = .legacy(tokenProvider, refreshAuthentication)
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Required captured normal context; construction never reads/migrates storage.
    init(baseURL: URL, session: URLSession, credentialAuthority: SessionCredentialAuthority,
         workerClient: WorkerClient, credentialContext: CredentialRequestContext,
         requestTimeout: TimeInterval = 30) throws {
        guard case .normal = credentialContext,
              workerClient.usesCredentialAuthority(credentialAuthority) else { throw CredentialAuthenticationFailure.accountChanged }
        self.baseURL = baseURL
        self.session = session
        self.authentication = .scoped(credentialAuthority, workerClient, credentialContext)
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private init(baseURL: URL, session: URLSession, admittedCleanupBearer: String, requestTimeout: TimeInterval) {
        self.baseURL = baseURL
        self.session = session
        self.authentication = .admittedCleanup(admittedCleanupBearer)
        self.requestTimeout = requestTimeout
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private func currentSnapshot() throws -> CredentialSnapshot? {
        guard case .scoped(let authority, _, let context) = authentication else { return nil }
        return try authority.snapshot(for: context)
    }

    private var canRefresh: Bool {
        switch authentication {
        case .legacy(_, let refresh): return refresh != nil
        case .scoped: return true
        case .admittedCleanup: return false
        }
    }

    private func refreshAuthentication(failed: CredentialRejectionContext?) async throws {
        switch authentication {
        case .legacy(_, let refresh):
            guard let refresh else { throw SharedReadingError.from(code: .authRequired) }
            try await refresh()
        case .scoped(_, let worker, let context):
            guard let failed else { throw CredentialAuthenticationFailure.reauthenticationRequired }
            _ = try await worker.refreshAuthentication(credentialContext: context, failed: failed)
        case .admittedCleanup:
            throw SharedReadingError.from(code: .authRequired)
        }
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
        if case .scoped = authentication { throw SharedReadingError.from(code: .accountChanged) }
        return try await send(path: "\(Self.routePrefix)/redeem", method: "POST", body: ["token": token])
    }

    /// The cleanup client keeps the *actual* bearer used by this redeem
    /// request, including a refreshed bearer. A late account transition must
    /// never turn its compensating leave into a request from the next account.
    func redeemWithAccountBoundCleanup(token: String) async throws -> (
        response: SharedReadingRedeemResponse,
        cleanupAPI: SharedReadingAPI
    ) {
        let (response, bearer): (SharedReadingRedeemResponse, String) = try await sendWithAuthorization(
            path: "\(Self.routePrefix)/redeem",
            method: "POST",
            body: ["token": token],
            didRefreshAuthentication: false,
            admitsLateCreation: true
        )
        return (response, accountBoundCleanupAPI(bearer: bearer))
    }

    private func accountBoundCleanupAPI(bearer: String) -> SharedReadingAPI {
        SharedReadingAPI(
            baseURL: baseURL,
            session: session,
            admittedCleanupBearer: bearer,
            requestTimeout: requestTimeout
        )
    }

    func markBookReady(sessionId: String, token: String, contentHash: String) async throws -> SharedReadingAdmission {
        try await send(path: "\(Self.routePrefix)/\(sessionId)/book-ready", method: "POST", body: ["token": token, "contentHash": contentHash])
    }

    func rejoin(sessionId: String, contentHash: String) async throws -> SharedReadingAdmission {
        if case .scoped = authentication { throw SharedReadingError.from(code: .accountChanged) }
        return try await send(path: "\(Self.routePrefix)/\(sessionId)/rejoin", method: "POST", body: ["contentHash": contentHash])
    }

    func rejoinWithAccountBoundCleanup(sessionId: String, contentHash: String) async throws -> (
        admission: SharedReadingAdmission,
        cleanupAPI: SharedReadingAPI
    ) {
        let (admission, bearer): (SharedReadingAdmission, String) = try await sendWithAuthorization(
            path: "\(Self.routePrefix)/\(sessionId)/rejoin",
            method: "POST",
            body: ["contentHash": contentHash],
            didRefreshAuthentication: false,
            admitsLateCreation: true
        )
        return (admission, accountBoundCleanupAPI(bearer: bearer))
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
        do {
            switch authentication {
            case .legacy(let provider, _):
                guard let token = await provider.token() else { throw SharedReadingError.from(code: .authRequired) }
                return token
            case .scoped:
                guard let snapshot = try currentSnapshot() else { throw CredentialAuthenticationFailure.reauthenticationRequired }
                socketRejectionContext = snapshot.rejectionContext
                return snapshot.session.token
            case .admittedCleanup(let bearer): return bearer
            }
        } catch { throw Self.refreshFailure(from: error) }
    }

    func refreshBearerToken() async throws -> String {
        guard canRefresh else {
            throw SharedReadingError.from(code: .authRequired)
        }
        do {
            Log.sharedReading(.authenticationRefresh, context: .init(outcome: .started))
            try await refreshAuthentication(failed: socketRejectionContext)
            let token = try await bearerToken()
            Log.sharedReading(.authenticationRefresh, context: .init(outcome: .completed))
            return token
        } catch {
            Log.sharedReading(.authenticationRefresh, level: .error, context: .init(outcome: .failed, errorCode: Self.diagnosticErrorCode(error)))
            throw Self.refreshFailure(from: error)
        }
    }

    private struct EmptyBody: Encodable {}

    private func send<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?) async throws -> Response {
        let (response, _): (Response, String) = try await sendWithAuthorization(
            path: path,
            method: method,
            body: body,
            didRefreshAuthentication: false
        )
        return response
    }

    private func sendWithAuthorization<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        didRefreshAuthentication: Bool,
        requestID: UUID = UUID(),
        admitsLateCreation: Bool = false
    ) async throws -> (Response, String) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw SharedReadingError.from(code: .serviceUnavailable) }
        let operation = Self.operation(for: path)
        let started = Date()
        Log.sharedReading(.apiRequest, context: .init(operation: operation, outcome: .started, operationID: requestID))
        var request = URLRequest(url: url)
        switch authentication {
        case .legacy: break
        case .scoped, .admittedCleanup: request.httpShouldHandleCookies = false
        }
        request.timeoutInterval = requestTimeout
        request.httpMethod = method
        request.setValue("v1", forHTTPHeaderField: "X-Rishi-API-Version")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Rishi-Request-ID")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Rishi-Correlation-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer: String
        let attemptedSnapshot: CredentialSnapshot?
        do { attemptedSnapshot = try currentSnapshot() }
        catch { throw Self.refreshFailure(from: error) }
        let token: String?
        switch authentication {
        case .legacy(let provider, _): token = await provider.token()
        case .scoped: token = attemptedSnapshot?.session.token
        case .admittedCleanup(let bearer): token = bearer
        }
        if let token {
            bearer = token
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            if !didRefreshAuthentication, canRefresh {
                do {
                    try await refreshAuthentication(failed: attemptedSnapshot?.rejectionContext)
                } catch {
                    Log.sharedReading(.authenticationRefresh, level: .error, context: .init(operation: operation, outcome: .failed, operationID: requestID, errorCode: Self.diagnosticErrorCode(error)))
                    throw Self.refreshFailure(from: error)
                }
                return try await sendWithAuthorization(
                    path: path,
                    method: method,
                    body: body,
                    didRefreshAuthentication: true,
                    requestID: requestID,
                    admitsLateCreation: admitsLateCreation
                )
            }
            throw SharedReadingError.from(code: .authRequired)
        }
        if let body { request.httpBody = try encoder.encode(body) }
        do {
            if attemptedSnapshot != nil { try Task.checkCancellation(); _ = try currentSnapshot() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SharedReadingError.from(code: .serviceUnavailable) }
            // Late admitted membership must reach its fixed-bearer cleanup owner.
            if !admitsLateCreation || !(200..<300).contains(http.statusCode) {
                _ = try currentSnapshot()
                if attemptedSnapshot != nil { try Task.checkCancellation() }
            }
            let correlationID = Self.safeCorrelationID(http.value(forHTTPHeaderField: "X-Rishi-Correlation-ID"))
            Log.sharedReading(.apiResponse, context: .init(
                operation: operation,
                outcome: .completed,
                correlationID: correlationID,
                operationID: requestID,
                statusCode: http.statusCode,
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000)
            ))
            if http.statusCode == 401, !didRefreshAuthentication, canRefresh {
                let rejectedRequest = decodeError(data, status: http.statusCode, path: path, response: http)
                do {
                    try await refreshAuthentication(failed: attemptedSnapshot?.rejectionContext)
                } catch {
                    Log.sharedReading(.authenticationRefresh, level: .error, context: .init(operation: operation, outcome: .failed, operationID: requestID, errorCode: Self.diagnosticErrorCode(error)))
                    throw Self.refreshFailure(
                        from: error,
                        correlationId: rejectedRequest.correlationId,
                        httpStatus: rejectedRequest.httpStatus
                    )
                }
                return try await sendWithAuthorization(
                    path: path,
                    method: method,
                    body: body,
                    didRefreshAuthentication: true,
                    requestID: requestID,
                    admitsLateCreation: admitsLateCreation
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                let error = decodeError(data, status: http.statusCode, path: path, response: http)
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
            do { return (try decoder.decode(Response.self, from: data), bearer) }
            catch {
                let decodeDiagnostic = Self.responseDecodingDiagnostic(error)
                let invalidResponse = SharedReadingError(
                    code: .invalidResponse,
                    message: "Rishi received an unexpected response while opening this reading session. Try again.",
                    retryable: true,
                    action: .retry,
                    correlationId: correlationID ?? requestID.uuidString,
                    stage: "\(operation.rawValue).response_decode",
                    httpStatus: http.statusCode,
                    diagnostic: decodeDiagnostic
                )
                Log.sharedReading(.apiFailure, level: .error, context: .init(
                    operation: operation,
                    outcome: .failed,
                    correlationID: invalidResponse.correlationId,
                    operationID: requestID,
                    statusCode: http.statusCode,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                    errorCode: invalidResponse.code.rawValue,
                    diagnostic: decodeDiagnostic
                ))
                throw invalidResponse
            }
        } catch let error as SharedReadingError {
            throw error
        } catch let error as CredentialAuthenticationFailure {
            throw Self.refreshFailure(from: error)
        } catch is CancellationError where attemptedSnapshot != nil {
            throw CancellationError()
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

    private func decodeError(_ data: Data, status: Int, path: String, response: HTTPURLResponse? = nil) -> SharedReadingError {
        struct Payload: Decodable {
            let code: String?
            let error: String?
            let retryable: Bool?
            let action: SharedReadingRecoveryAction?
            let correlationId: String?
            let stage: String?
            let diagnostic: String?
        }
        let payload = try? decoder.decode(Payload.self, from: data)
        let headerCode = response?.value(forHTTPHeaderField: "X-Rishi-Error-Code")
        let rawCode = payload?.code ?? headerCode
        let code = rawCode.flatMap(SharedReadingErrorCode.init(rawValue:))
        let correlationID = Self.safeCorrelationID(payload?.correlationId)
            ?? Self.safeCorrelationID(response?.value(forHTTPHeaderField: "X-Rishi-Correlation-ID"))
        let stage = payload?.stage ?? response?.value(forHTTPHeaderField: "X-Rishi-Error-Stage")
        let diagnostic = payload?.diagnostic ?? (code == nil ? rawCode : nil)
        if let payload, let code {
            let fallback = SharedReadingError.from(code: code, message: payload.error)
            return SharedReadingError(
                code: code,
                message: payload.error ?? fallback.message,
                retryable: payload.retryable ?? fallback.retryable,
                action: payload.action ?? fallback.action,
                correlationId: correlationID,
                stage: stage,
                httpStatus: status,
                diagnostic: diagnostic
            )
        }
        let fallbackCode: SharedReadingErrorCode
        if status == 401 { fallbackCode = .authRequired }
        else if status == 409 { fallbackCode = .roomFull }
        else if status == 403 { fallbackCode = .forbidden }
        else if status == 404 { fallbackCode = path == Self.routePrefix ? .serviceUnavailable : .sessionLinkInvalid }
        else if status == 410 { fallbackCode = .sessionEnded }
        else if status == 422 { fallbackCode = .bookHashMismatch }
        else { fallbackCode = .serviceUnavailable }
        let fallbackMessage = status == 404 && path == Self.routePrefix
            ? "The reading-session service is not available yet."
            : nil
        let fallback = SharedReadingError.from(code: fallbackCode, message: fallbackMessage)
        return SharedReadingError(
            code: fallbackCode,
            message: fallback.message,
            retryable: fallback.retryable,
            action: fallback.action,
            correlationId: correlationID,
            stage: stage,
            httpStatus: status,
            diagnostic: diagnostic
        )
    }

    private static func safeCorrelationID(_ value: String?) -> String? {
        guard let value, (1...100).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) })
        else { return nil }
        return value
    }

    private static func diagnosticErrorCode(_ error: Error) -> String {
        if let error = error as? SharedReadingError { return error.code.rawValue }
        if error is URLError { return "URL_ERROR" }
        return "UNKNOWN"
    }

    /// Log only the Decodable failure kind and coding-key path—never response
    /// values, signed URLs, tokens, or book content.
    private static func responseDecodingDiagnostic(_ error: Error) -> String {
        let kind: String
        let path: [CodingKey]
        switch error {
        case DecodingError.typeMismatch(_, let context):
            kind = "type_mismatch"
            path = context.codingPath
        case DecodingError.valueNotFound(_, let context):
            kind = "value_missing"
            path = context.codingPath
        case DecodingError.keyNotFound(let key, let context):
            kind = "key_missing"
            path = context.codingPath + [key]
        case DecodingError.dataCorrupted(let context):
            kind = "data_corrupted"
            path = context.codingPath
        default:
            kind = "decode_failure"
            path = []
        }
        let safePath = path.compactMap { key -> String? in
            let value = key.stringValue
            guard !value.isEmpty, value.utf8.count <= 40,
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) })
            else { return nil }
            return value
        }.joined(separator: ".")
        return safePath.isEmpty ? kind : "\(kind):\(safePath)"
    }

    private static func refreshFailure(
        from error: Error,
        correlationId: String? = nil,
        httpStatus: Int? = nil
    ) -> SharedReadingError {
        let failure: SharedReadingError
        if let error = error as? SharedReadingError {
            failure = error
        } else if let error = error as? CredentialAuthenticationFailure {
            switch error {
            case .accountChanged: failure = .from(code: .accountChanged)
            case .signedOut, .reauthenticationRequired, .definitiveRejection: failure = .from(code: .authRequired)
            case .unavailable: failure = .from(code: .serviceUnavailable)
            }
        } else {
            failure = .from(code: .serviceUnavailable)
        }
        return SharedReadingError(
            code: failure.code,
            message: failure.message,
            retryable: failure.retryable,
            action: failure.action,
            correlationId: failure.correlationId ?? correlationId,
            stage: failure.stage ?? "auth.refresh",
            httpStatus: failure.httpStatus ?? httpStatus,
            diagnostic: failure.diagnostic ?? (error is SharedReadingError ? nil : diagnosticErrorCode(error))
        )
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

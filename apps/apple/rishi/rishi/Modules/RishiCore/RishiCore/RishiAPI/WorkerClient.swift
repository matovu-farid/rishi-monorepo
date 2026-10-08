import Foundation

/// Admission only: transport never joins the resulting account cleanup task.
enum CredentialRetirementAdmission: Sendable {
    case admitted(UUID)
    case duplicate(UUID)
    case stale
}

/// Only remote creations need late-success delivery for original-bearer cleanup.
struct AdmittedCredentialResponse<Response: Sendable>: Sendable {
    let response: Response
    let lease: CredentialLease
    let transmittedBearer: String
}

/// Single networking surface for the Rishi worker. Inject one `WorkerClient`
/// per app + per test; pass it around as `any Sendable`. The actor isolation
/// makes the retry + breadcrumb state safe under Swift 6 strict concurrency.
public actor WorkerClient {

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: (any TokenProvider)?
    private let scopedCredentials: ScopedCredentials?
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider
    private let devBypassEnabled: Bool
    private let devBypassSecret: String?
    private var scopedRefreshes: [RefreshKey: RefreshEntry] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Retry attempt cap (total, including the initial try). Phase 2 fixes this
    /// at 3 per requirement API-01; revisit if 5xx tail-latency becomes a problem.
    private let maxAttempts = 3

    private struct ScopedCredentials: Sendable {
        let authority: SessionCredentialAuthority
        let admitRejection: @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission
    }
    private enum RequestScope: Sendable {
        case authenticated(CredentialRequestContext)
        case anonymous(CredentialAttemptTicket)
        case authentication(CredentialAttemptTicket)
    }
    private struct RefreshKey: Hashable, Sendable {
        let lease: CredentialLease
        let revision: UInt64
    }
    private struct RefreshEntry {
        let id: UUID
        let task: Task<CredentialSnapshot, Error>
    }
    private struct BuiltRequest {
        let request: URLRequest
        let snapshot: CredentialSnapshot?
    }
    private struct ResponseDelivery<Response: Sendable>: Sendable {
        let response: Response
        let snapshot: CredentialSnapshot?
        let bearer: String?
    }
    private struct ScopedUnauthorized: Error {
        let failed: CredentialRejectionContext?
    }

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any TokenProvider,
        dataUseConsentProvider: any WorkerDataUseConsentProvider = NoWorkerDataUseConsentProvider(),
        devBypassEnabled: Bool = false,
        devBypassSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.scopedCredentials = nil
        self.dataUseConsentProvider = dataUseConsentProvider
        self.devBypassEnabled = devBypassEnabled
        self.devBypassSecret = devBypassSecret
    }

    /// Passive until the atomic app cutover. No credential read or default authority.
    init(
        baseURL: URL, session: URLSession,
        credentialAuthority: SessionCredentialAuthority,
        dataUseConsentProvider: any WorkerDataUseConsentProvider,
        admitCredentialRejection: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = nil
        self.scopedCredentials = ScopedCredentials(authority: credentialAuthority, admitRejection: admitCredentialRejection)
        self.dataUseConsentProvider = dataUseConsentProvider
        self.devBypassEnabled = false
        self.devBypassSecret = nil
    }

    /// Fixed-bearer, nonrefreshing compensation for an already admitted remote creation.
    init(baseURL: URL, session: URLSession, admittedCleanupBearer: String,
         dataUseConsentProvider: any WorkerDataUseConsentProvider) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = StaticTokenProvider(admittedCleanupBearer)
        self.scopedCredentials = nil
        self.dataUseConsentProvider = dataUseConsentProvider
        self.devBypassEnabled = false
        self.devBypassSecret = nil
    }

    /// Identity check for required captured-context adapter construction.
    nonisolated func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        scopedCredentials?.authority === authority
    }

    /// Whether this client can make a consented authenticated AI request.
    /// This is a probe only; the endpoint still enforces the same headers when
    /// the request is built and sent.
    public func hasAuthenticatedAIRequestAccess() async -> Bool {
        let scope = try? captureScope()
        let hasToken: Bool
        if scopedCredentials != nil {
            hasToken = (try? resolve(scope)) != nil
        } else { hasToken = await tokenProvider?.token() != nil }
        let hasConsent = await dataUseConsentProvider.hasCurrentDataUseConsent()
        if scopedCredentials != nil, (try? resolve(scope)) == nil { return false }
        return hasToken && hasConsent
    }

    /// Refresh the bearer token for callers that use the same session
    /// credentials outside of a `WorkerEndpoint` request.
    public func refreshAuthentication() async throws {
        // External transports must supply their original lease/rejected revision.
        throw CredentialAuthenticationFailure.reauthenticationRequired
    }

    /// External adapters retain the original normal lease and rejected revision.
    func refreshAuthentication(
        credentialContext: CredentialRequestContext,
        failed: CredentialRejectionContext
    ) async throws -> CredentialSnapshot {
        guard scopedCredentials != nil, case .normal(let lease) = credentialContext else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        let scope = RequestScope.authenticated(credentialContext)
        guard let current = try resolve(scope), failed.lease == lease,
              failed.ticket == current.ticket, failed.tokenRevision <= current.tokenRevision else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        try Task.checkCancellation()
        return try await refreshScoped(scope: scope, failed: failed)
    }

    // MARK: - Non-streaming send

    /// Send a typed endpoint, retrying transient failures with exponential backoff.
    public func send<E: WorkerEndpoint>(
        _ endpoint: E
    ) async throws -> E.Response {
        try await sendCaptured(endpoint, scope: captureScope(), admitsLateCreation: false).response
    }

    /// Provider exchange is intentionally anonymous even if an account is
    /// installed. Its original attempt ticket owns every retry and response.
    func sendAuthentication<E: WorkerEndpoint>(
        _ endpoint: E, expectedCredentialTicket: CredentialAttemptTicket
    ) async throws -> E.Response {
        guard scopedCredentials != nil, !endpoint.requiresDataUseConsent else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        // URLSession merges configured headers after building a URLRequest.
        // Reject credential-bearing configurations rather than create another client.
        let credentialHeaders = session.configuration.httpAdditionalHeaders?.keys.contains { key in
            guard let name = key as? String else { return false }
            return name.caseInsensitiveCompare("Authorization") == .orderedSame ||
                   name.caseInsensitiveCompare("Cookie") == .orderedSame
        } ?? false
        guard !credentialHeaders else { throw CredentialAuthenticationFailure.accountChanged }
        let scope = RequestScope.authentication(expectedCredentialTicket)
        try validate(scope)
        return try await sendCaptured(endpoint, scope: scope, admitsLateCreation: false).response
    }

    /// Outgoing account deletion supplies the exact transaction-bound context.
    func send<E: WorkerEndpoint>(_ endpoint: E, credentialContext: CredentialRequestContext) async throws -> E.Response {
        guard scopedCredentials != nil else { throw CredentialAuthenticationFailure.accountChanged }
        let scope = RequestScope.authenticated(credentialContext)
        try validate(scope)
        return try await sendCaptured(endpoint, scope: scope, admitsLateCreation: false).response
    }

    func sendAdmittedCreation<E: WorkerEndpoint>(_ endpoint: E) async throws -> AdmittedCredentialResponse<E.Response> {
        guard scopedCredentials != nil else { throw CredentialAuthenticationFailure.accountChanged }
        let scope = try captureScope()
        guard try resolve(scope) != nil else { throw CredentialAuthenticationFailure.reauthenticationRequired }
        let delivery = try await sendCaptured(endpoint, scope: scope, admitsLateCreation: true)
        guard let snapshot = delivery.snapshot, let bearer = delivery.bearer else {
            throw CredentialAuthenticationFailure.reauthenticationRequired
        }
        return AdmittedCredentialResponse(response: delivery.response, lease: snapshot.lease, transmittedBearer: bearer)
    }

    /// Creation is admitted before per-session objects are constructed. A late
    /// successful response still carries its actual bearer for compensation.
    func sendAdmittedCreation<E: WorkerEndpoint>(
        _ endpoint: E,
        credentialContext: CredentialRequestContext
    ) async throws -> AdmittedCredentialResponse<E.Response> {
        guard scopedCredentials != nil, case .normal = credentialContext else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        let scope = RequestScope.authenticated(credentialContext)
        try validate(scope)
        let delivery = try await sendCaptured(endpoint, scope: scope, admitsLateCreation: true)
        guard let snapshot = delivery.snapshot, let bearer = delivery.bearer else {
            throw CredentialAuthenticationFailure.reauthenticationRequired
        }
        return AdmittedCredentialResponse(response: delivery.response, lease: snapshot.lease, transmittedBearer: bearer)
    }

    private func sendCaptured<E: WorkerEndpoint>(
        _ endpoint: E, scope: RequestScope?, admitsLateCreation: Bool
    ) async throws -> ResponseDelivery<E.Response> {
        
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            
            if attempt > 1 {
                let delaySeconds =
                pow(2.0, Double(attempt - 1)) * 0.5
                
               
                try await Task.sleep(
                    for: .seconds(delaySeconds)
                )
            }
            
            do {
                
                return try await performAuthenticatedRequest(
                    endpoint,
                    attempt: attempt, scope: scope, admitsLateCreation: admitsLateCreation
                )
                
            } catch let error as RishiError {
                
                switch error {
                    
                case .networkFailure(let urlError):
                    
                    if isRetryable(urlError),
                       attempt < maxAttempts {
                        
                        lastError = error
                        continue
                    }
                    
                    throw error
                    
                default:
                    throw error
                }
                
            } catch {
                
                throw error
            }
        }
        
        throw lastError!
    }
    
    private func performAuthenticatedRequest<E: WorkerEndpoint>(
        _ endpoint: E,
        attempt: Int, scope: RequestScope?, admitsLateCreation: Bool
    ) async throws -> ResponseDelivery<E.Response> {
        
        do {
            return try await performAttempt(endpoint, attempt: attempt, scope: scope, admitsLateCreation: admitsLateCreation)
        } catch let rejected as ScopedUnauthorized {
            if case .authentication = scope {
                throw CredentialAuthenticationFailure.reauthenticationRequired
            }
            _ = try await refreshScoped(scope: scope, failed: rejected.failed)
            do {
                return try await performAttempt(endpoint, attempt: attempt, scope: scope, admitsLateCreation: admitsLateCreation)
            } catch is ScopedUnauthorized {
                throw CredentialAuthenticationFailure.reauthenticationRequired
            }
        } catch RishiError.unauthenticated {
            throw CredentialAuthenticationFailure.reauthenticationRequired
        }
    }
    /// Stream raw transport bytes from a worker endpoint.
    ///
    /// Domain-specific callers, such as the TTS client, are responsible for
    /// turning those bytes into their own ordered chunk model.
    public nonisolated func stream<E: WorkerStreamingEndpoint>(
        _ endpoint: E
    ) async -> AsyncThrowingStream<Data, Error> {
        
        await makeStream(endpoint)
    }

    /// Downloads and validates one complete binary response.
    public func downloadData<E: WorkerStreamingEndpoint>(_ endpoint: E) async throws -> Data {
        let scope = try captureScope()
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1)) * 0.5))
            }
            do {
                return try await downloadAttempt(endpoint, scope: scope)
            } catch let rejected as ScopedUnauthorized {
                _ = try await refreshScoped(scope: scope, failed: rejected.failed)
                do { return try await downloadAttempt(endpoint, scope: scope) }
                catch is ScopedUnauthorized { throw CredentialAuthenticationFailure.reauthenticationRequired }
            } catch RishiError.unauthenticated {
                throw CredentialAuthenticationFailure.reauthenticationRequired
            } catch let error as RishiError {
                if case .networkFailure(let urlError) = error,
                   isRetryable(urlError),
                   attempt < maxAttempts {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }
        throw lastError ?? RishiError.network(code: "download_failed", message: "")
    }

    private func downloadAttempt<E: WorkerStreamingEndpoint>(_ endpoint: E, scope: RequestScope?) async throws -> Data {
        let built = try await buildStreamingRequest(for: endpoint, scope: scope)
        let request = built.request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw RishiError.networkFailure(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RishiError.network(code: "invalid_response", message: "")
        }
        try validate(scope)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                if scopedCredentials != nil { throw ScopedUnauthorized(failed: built.snapshot?.rejectionContext) }
                throw RishiError.unauthenticated
            }
            if let allowance = Self.decodeAllowanceError(from: data) {
                throw allowance
            }
            let fields = decodeWorkerErrorFields(from: data, status: http.statusCode)
            throw RishiError.network(code: fields.code, message: fields.message)
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            throw RishiError.network(code: "invalid_content_encoding", message: "Complete audio must not be encoded")
        }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type") else {
            throw RishiError.network(code: "invalid_content_type", message: "Missing Content-Type")
        }
        let mediaType = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mediaType == "audio/mpeg" else {
            throw RishiError.network(code: "invalid_content_type", message: "Expected audio/mpeg")
        }
        guard let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
              let expected = Int(contentLength.trimmingCharacters(in: .whitespacesAndNewlines)),
              expected >= 0, expected == data.count else {
            throw RishiError.network(code: "invalid_content_length", message: "Content-Length does not match body")
        }
        return data
    }
    private func makeStream<E: WorkerStreamingEndpoint>(
        _ endpoint: E
    ) -> AsyncThrowingStream<Data, Error> {
        let scope: RequestScope?
        do { scope = try captureScope() }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        
        return AsyncThrowingStream { continuation in
            
            let task = Task {
                
                do {
                    
                    let built =
                    try await buildStreamingRequest(
                        for: endpoint, scope: scope
                    )
                    let request = built.request
                    
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw RishiError.network(code: "invalid_response", message: "")
                    }
                    try validate(scope)

                    if http.statusCode == 401 {
                        if scopedCredentials != nil {
                            _ = try await refreshScoped(scope: scope, failed: built.snapshot?.rejectionContext)
                        } else { throw CredentialAuthenticationFailure.reauthenticationRequired }

                        let retry = try await buildStreamingRequest(for: endpoint, scope: scope)
                        let (retryBytes, retryResponse) = try await session.bytes(for: retry.request)
                        try validate(scope)
                        if scopedCredentials != nil, (retryResponse as? HTTPURLResponse)?.statusCode == 401 {
                            throw CredentialAuthenticationFailure.reauthenticationRequired
                        }
                        try await Self.consumeStreamingBody(
                            bytes: retryBytes,
                            response: retryResponse
                        ) { try self.emit($0, scope: scope, to: continuation) }
                        try validate(scope)
                        continuation.finish()
                        return
                    }

                    try await Self.consumeStreamingBody(
                        bytes: bytes,
                        response: http
                    ) { try self.emit($0, scope: scope, to: continuation) }
                    try validate(scope)
                    continuation.finish()
                    
                } catch {
                    
                    continuation.finish(
                        throwing: error
                    )
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func consumeStreamingBody(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        yield: @escaping (Data) throws -> Void
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw RishiError.network(code: "invalid_response", message: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            if let allowance = Self.decodeAllowanceError(from: body) {
                throw allowance
            }
            throw RishiError.network(code: "http_\(http.statusCode)", message: "")
        }

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4096 {
                try yield(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try yield(buffer)
        }
    }

    private func performAttempt<E: WorkerEndpoint>(
        _ endpoint: E, attempt: Int, scope: RequestScope?, admitsLateCreation: Bool
    ) async throws -> ResponseDelivery<E.Response> {
        let built = try await buildRequest(for: endpoint, scope: scope)
        let request = built.request
        let started = Date()
        let requestID = request.value(forHTTPHeaderField: "X-Rishi-Request-ID") ?? "missing"
        Log.event("worker.request.started", data: [
            "method": endpoint.method.rawValue,
            "path": endpoint.path,
            "apiVersion": request.value(forHTTPHeaderField: "X-Rishi-API-Version") ?? "legacy",
            "requestId": requestID,
            "attempt": String(attempt),
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            Log.event("worker.request.failed", level: .error, data: [
                "path": endpoint.path,
                "requestId": requestID,
                "attempt": String(attempt),
                "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000)),
                "error": urlError.localizedDescription,
            ])
            throw RishiError.networkFailure(urlError)
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if !admitsLateCreation || !(200..<300).contains(status) { try validate(scope) }
        Log.event("worker.response.received", data: [
            "path": endpoint.path,
            "requestId": requestID,
            "status": String(status),
            "durationMs": String(Int(Date().timeIntervalSince(started) * 1_000)),
        ])

        if endpoint.path == "/api/shares/redeem" {
            Log.event("sharing.worker.redeem.response", data: [
                "status": String(status),
                "attempt": String(attempt),
            ])
        }

  

        switch status {
        case 200..<300:
            do {
                let response = try decoder.decode(E.Response.self, from: data)
                return ResponseDelivery(response: response, snapshot: built.snapshot,
                                        bearer: request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) })
            } catch {
                Log.event("worker.response.decode_failed", level: .error, data: [
                    "path": endpoint.path,
                    "requestId": requestID,
                    "error": String(describing: error),
                ])
                throw RishiError.decoding("Failed to decode \(E.Response.self) at \(endpoint.path): \(error)")
            }
        case 401:
            if scopedCredentials != nil { throw ScopedUnauthorized(failed: built.snapshot?.rejectionContext) }
            throw RishiError.unauthenticated
        case 400..<500:
            if let allowance = Self.decodeAllowanceError(from: data) {
                throw allowance
            }
            let (code, message) = decodeWorkerErrorFields(from: data, status: status)
            throw RishiError.network(code: code, message: message)
        case 500..<600:
            // Decode before retrying. Idempotent POSTs can mutate server state
            // then return 5xx with an app code (e.g. voice-session create →
            // 502 OPENAI_MINT_FAILED after the ledger session exists). Blind
            // retries then hit 409 VOICE_SESSION_ALREADY_ACTIVE. Only empty /
            // unparseable 5xx bodies keep the transient-retry path.
            if let allowance = Self.decodeAllowanceError(from: data) {
                throw allowance
            }
            if let appError = decodeTypedWorkerError(from: data) {
                throw RishiError.network(code: appError.code, message: appError.message)
            }
            if attempt < maxAttempts {
                throw RishiError.networkFailure(URLError(.networkConnectionLost))
            }
            throw RishiError.network(code: "http_5xx", message: "HTTP \(status)")
        default:
            throw RishiError.network(code: "http_unknown", message: "HTTP \(status)")
        }
    }

    /// Decodes a 4xx/5xx body into `(code, message)`. Tries the nested
    /// `{ error: { code, message } }` shape most worker routes use
    /// (`ErrorEnvelope`) first — preserving every existing route's behavior
    /// unchanged — then the flat `{ error, code }` shape the voice-session
    /// routes return, then falls back to a generic `http_4xx` code so an
    /// unparseable body never throws a decoding error instead of the
    /// intended `RishiError.network`. See
    /// `2026-07-17-voice-session-flow-wiring.md` Task 1.
    private func decodeWorkerErrorFields(from data: Data, status: Int) -> (code: String, message: String) {
        if let typed = decodeTypedWorkerError(from: data) {
            return typed
        }
        return ("http_4xx", "HTTP \(status)")
    }

    /// Returns a typed app error when the body is a nested `ErrorEnvelope` or
    /// flat `FlatErrorEnvelope`; `nil` for empty/unparseable bodies.
    private func decodeTypedWorkerError(from data: Data) -> (code: String, message: String)? {
        if let nested = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return (nested.code, nested.message)
        }
        if let flat = try? decoder.decode(FlatErrorEnvelope.self, from: data) {
            return (flat.code, flat.error)
        }
        return nil
    }

    private static func decodeAllowanceError(from data: Data) -> WorkerAllowanceError? {
        // The worker contract uses HTTP 402, but the stable typed code is the
        // authoritative signal. Keeping this independent of status preserves
        // the upgrade path if an older worker or intermediary incorrectly
        // returns the typed envelope with a 5xx status.
        guard let flat = try? JSONDecoder().decode(FlatErrorEnvelope.self, from: data),
              flat.code == WorkerErrorCode.insufficientAllowance
        else { return nil }

        let normalizedKind = flat.allowanceKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind: WorkerAllowanceKind
        if normalizedKind == WorkerAllowanceKind.trial.rawValue {
            kind = .trial
        } else if normalizedKind == WorkerAllowanceKind.narration.rawValue {
            kind = .narration
        } else if flat.error.lowercased().contains("narration allowance") ||
                    flat.error.lowercased().contains("billing period") {
            // Older workers omitted allowance_kind for paid narration. Keep
            // that compatibility behavior while remaining strict on `code`.
            kind = .narration
        } else {
            kind = .trial
        }
        switch kind {
        case .trial: return .trial(message: flat.error)
        case .narration: return .narration(message: flat.error)
        }
    }

    private func isRetryable(_ urlError: URLError) -> Bool {
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }


    // MARK: - Captured credential transport

    private nonisolated func captureScope() throws -> RequestScope? {
        guard let credentials = scopedCredentials else { return nil }
        let ticket = credentials.authority.attemptTicket()
        do { return .authenticated(.normal(try credentials.authority.snapshot().lease)) }
        catch CredentialAuthenticationFailure.signedOut { return .anonymous(ticket) }
    }

    private nonisolated func resolve(_ scope: RequestScope?) throws -> CredentialSnapshot? {
        guard let credentials = scopedCredentials else { return nil }
        guard let scope else { throw CredentialAuthenticationFailure.accountChanged }
        switch scope {
        case .authenticated(let context): return try credentials.authority.snapshot(for: context)
        case .authentication(let ticket):
            try Task.checkCancellation()
            guard credentials.authority.attemptTicket() == ticket else {
                throw CredentialAuthenticationFailure.accountChanged
            }
            return nil
        case .anonymous(let ticket):
            guard credentials.authority.attemptTicket() == ticket else { throw CredentialAuthenticationFailure.accountChanged }
            do {
                _ = try credentials.authority.snapshot()
                throw CredentialAuthenticationFailure.accountChanged
            } catch CredentialAuthenticationFailure.signedOut { return nil }
        }
    }

    private nonisolated func validate(_ scope: RequestScope?) throws { _ = try resolve(scope) }

    private func applyAuthorization(scope: RequestScope?, to request: inout URLRequest) async throws -> CredentialSnapshot? {
        if scopedCredentials != nil {
            // Consent is an external await; resolve the original context afterward.
            let snapshot = try resolve(scope)
            if let snapshot { request.setValue("Bearer \(snapshot.session.token)", forHTTPHeaderField: "Authorization") }
            return snapshot
        }
        if let token = await tokenProvider?.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return nil
    }

    private nonisolated func emit(_ data: Data, scope: RequestScope?, to continuation: AsyncThrowingStream<Data, Error>.Continuation) throws {
        if let credentials = scopedCredentials {
            try Task.checkCancellation()
            try validate(scope)
            if case .authenticated(.normal(let lease)) = scope {
                guard credentials.authority.performIfCurrent(lease, mutation: { continuation.yield(data) }) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
                return
            }
        }
        continuation.yield(data)
    }

    private func refreshScoped(scope: RequestScope?, failed: CredentialRejectionContext?) async throws -> CredentialSnapshot {
        guard let credentials = scopedCredentials,
              let scope, case .authenticated(.normal) = scope,
              let current = try resolve(scope), let failed else {
            throw CredentialAuthenticationFailure.reauthenticationRequired
        }
        guard current.lease == failed.lease else { throw CredentialAuthenticationFailure.accountChanged }
        if current.tokenRevision != failed.tokenRevision { return current }
        guard current.rejectionContext == failed else { throw CredentialAuthenticationFailure.accountChanged }
        guard current.refreshToken != nil else { throw CredentialAuthenticationFailure.reauthenticationRequired }
        try Task.checkCancellation()
        let key = RefreshKey(lease: current.lease, revision: current.tokenRevision)
        let task: Task<CredentialSnapshot, Error>
        if let entry = scopedRefreshes[key] { task = entry.task }
        else {
            let id = UUID()
            task = Task { [self] in
                defer { if scopedRefreshes[key]?.id == id { scopedRefreshes[key] = nil } }
                return try await actuallyRefreshScoped(expected: current, credentials: credentials)
            }
            scopedRefreshes[key] = RefreshEntry(id: id, task: task)
        }
        let result = try await task.value
        try Task.checkCancellation()
        try validate(scope)
        return result
    }

    private func actuallyRefreshScoped(expected: CredentialSnapshot, credentials: ScopedCredentials) async throws -> CredentialSnapshot {
        let context = CredentialRequestContext.normal(expected.lease)
        let current = try credentials.authority.snapshot(for: context)
        if current.tokenRevision != expected.tokenRevision { return current }
        guard let refreshToken = expected.refreshToken else { throw CredentialAuthenticationFailure.reauthenticationRequired }
        var request = URLRequest(url: makeURL(path: "/auth/refresh"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let refreshToken: String }
        request.httpBody = try encoder.encode(Body(refreshToken: refreshToken))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError { throw RishiError.networkFailure(error) }

        // Fence/revision first: an old failure can never retire the new owner/token.
        let latest = try credentials.authority.snapshot(for: context)
        if latest.tokenRevision != expected.tokenRevision { return latest }
        guard let http = response as? HTTPURLResponse else {
            throw RishiError.network(code: "invalid_response", message: "")
        }
        if http.statusCode == 401 {
            let code = decodeTypedWorkerError(from: data)?.code
            if code == CredentialRejectionCode.invalidRefreshToken.rawValue {
                return try await rejectScoped(.invalidRefreshToken, expected: expected, credentials: credentials)
            }
            if code == CredentialRejectionCode.refreshAccountUnavailable.rawValue {
                return try await rejectScoped(.refreshAccountUnavailable, expected: expected, credentials: credentials)
            }
            // Legacy401 conflates credentials and infrastructure; preserve storage.
            throw CredentialAuthenticationFailure.reauthenticationRequired
        }
        guard http.statusCode == 200 else {
            throw RishiError.network(code: "refresh_http_\(http.statusCode)", message: "Refresh could not complete")
        }
        struct Tokens: Decodable { let accessToken: String; let refreshToken: String; let userId: String? }
        let tokens: Tokens
        do { tokens = try decoder.decode(Tokens.self, from: data) }
        catch { throw RishiError.decoding("Invalid refresh response") }
        if let owner = tokens.userId, owner != expected.session.userId {
            return try await rejectScoped(.identityMismatch, expected: expected, credentials: credentials)
        }
        return try credentials.authority.commitRefresh(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                                        issuedAt: Date(), expected: expected)
    }

    private func rejectScoped(_ code: CredentialRejectionCode, expected: CredentialSnapshot,
                              credentials: ScopedCredentials) async throws -> CredentialSnapshot {
        let current = try credentials.authority.snapshot(for: .normal(expected.lease))
        guard current.rejectionContext == expected.rejectionContext else { throw CredentialAuthenticationFailure.accountChanged }
        // This callback admits/schedules retirement; it must never await its drain.
        let admission = await credentials.admitRejection(code, expected.rejectionContext)
        if case .stale = admission { throw CredentialAuthenticationFailure.accountChanged }
        throw CredentialAuthenticationFailure.definitiveRejection(code, expected.rejectionContext)
    }

    // MARK: - Request building

    /// Build the request URL from an endpoint path that MAY embed a query
    /// string. `URL.append(path:)` is for path components and percent-encodes
    /// reserved characters, so a "/x?since=y" path would have its "?" turned
    /// into "%3F" and break worker routing (404). Split any query off and attach
    /// it as a real, already-encoded query component instead.
    private func makeURL(path: String) -> URL {
        guard let qIndex = path.firstIndex(of: "?") else {
            var url = baseURL
            url.append(path: path)
            return url
        }
        var url = baseURL
        url.append(path: String(path[..<qIndex]))
        let query = String(path[path.index(after: qIndex)...])
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.percentEncodedQuery = query
        return components.url ?? url
    }
   

    func buildRequest<E: WorkerEndpoint>(for endpoint: E) async throws -> URLRequest {
        try await buildRequest(for: endpoint, scope: captureScope()).request
    }

    private func buildRequest<E: WorkerEndpoint>(for endpoint: E, scope: RequestScope?) async throws -> BuiltRequest {
        try validate(scope)
        let url = makeURL(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Native bearer-token client: never attach or store cookies. Better Auth's
        // origin check only fires when a Cookie header is present, so a stray stored
        // session cookie would trip a 403 MISSING_OR_NULL_ORIGIN on Bearer requests.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyRequestMetadata(for: endpoint.path, to: &request)
        try await applyDataUseConsentHeaderIfNeeded(
            endpoint.requiresDataUseConsent,
            to: &request
        )

        let snapshot = try await applyAuthorization(scope: scope, to: &request)
        #if DEBUG
        if devBypassEnabled {
            request.setValue(devBypassSecret ?? "1", forHTTPHeaderField: "X-Dev-Bypass")
        }
        if endpoint.path == "/test/sign-in",
           let testAuthSecret = ProcessInfo.processInfo.environment["RISHI_E2E_TEST_AUTH_SECRET"],
           !testAuthSecret.isEmpty {
            request.setValue(testAuthSecret, forHTTPHeaderField: "X-Test-Auth-Secret")
        }
        #endif

        // Any non-GET request declares JSON, even bodyless ones (e.g. sign-out),
        // otherwise Better Auth rejects the bodyless POST with 415.
        if endpoint.method.rawValue != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bodied = endpoint as? (any WorkerEndpointWithBody) {
            request.httpBody = try encoder.encode(AnyEncodable(bodied.body))
        }
        if case .authentication = scope {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return BuiltRequest(request: request, snapshot: snapshot)
    }

    func buildStreamingRequest<E: WorkerStreamingEndpoint>(
        for endpoint: E
    ) async throws -> URLRequest {
        try await buildStreamingRequest(for: endpoint, scope: captureScope()).request
    }

    private func buildStreamingRequest<E: WorkerStreamingEndpoint>(
        for endpoint: E, scope: RequestScope?
    ) async throws -> BuiltRequest {
        try validate(scope)
        let url = makeURL(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Native bearer-token client: never attach/store cookies (see buildRequest).
        request.httpShouldHandleCookies = false
        applyRequestMetadata(for: endpoint.path, to: &request)
        try await applyDataUseConsentHeaderIfNeeded(
            endpoint.requiresDataUseConsent,
            to: &request
        )

        let snapshot = try await applyAuthorization(scope: scope, to: &request)
        #if DEBUG
        if devBypassEnabled {
            request.setValue(devBypassSecret ?? "1", forHTTPHeaderField: "X-Dev-Bypass")
        }
        #endif
        if let bodied = endpoint as? (any WorkerStreamingEndpointWithBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(bodied.body))
        }
        return BuiltRequest(request: request, snapshot: snapshot)
    }

    private func applyRequestMetadata(for path: String, to request: inout URLRequest) {
        let version = path.hasPrefix("/api/v1/") ? "v1" : "legacy"
        request.setValue(version, forHTTPHeaderField: "X-Rishi-API-Version")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Rishi-Request-ID")
    }

    private func applyDataUseConsentHeaderIfNeeded(
        _ required: Bool,
        to request: inout URLRequest
    ) async throws {
        guard required else { return }
        guard await dataUseConsentProvider.hasCurrentDataUseConsent() else {
            throw WorkerDataUseConsentRequiredError()
        }
        request.setValue(
            WorkerDataUseConsent.currentVersion,
            forHTTPHeaderField: WorkerDataUseConsent.headerField
        )
    }
}

// MARK: - AnyEncodable shim

    /// Type-eraser so `JSONEncoder` can encode an `any Encodable & Sendable` value
/// without forcing every endpoint body to a single concrete type.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<E: Encodable>(_ value: E) { self._encode = value.encode(to:) }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

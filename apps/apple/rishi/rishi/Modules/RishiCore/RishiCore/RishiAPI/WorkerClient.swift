import Foundation

/// Single networking surface for the Rishi worker. Inject one `WorkerClient`
/// per app + per test; pass it around as `any Sendable`. The actor isolation
/// makes the retry + breadcrumb state safe under Swift 6 strict concurrency.
public actor WorkerClient {

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any TokenProvider
    private let dataUseConsentProvider: any WorkerDataUseConsentProvider
    private let devBypassEnabled: Bool
    private let devBypassSecret: String?
    private var refreshTask: Task<Void, Error>?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Retry attempt cap (total, including the initial try). Phase 2 fixes this
    /// at 3 per requirement API-01; revisit if 5xx tail-latency becomes a problem.
    private let maxAttempts = 3

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
        self.dataUseConsentProvider = dataUseConsentProvider
        self.devBypassEnabled = devBypassEnabled
        self.devBypassSecret = devBypassSecret
    }

    /// Whether this client can make a consented authenticated AI request.
    /// This is a probe only; the endpoint still enforces the same headers when
    /// the request is built and sent.
    public func hasAuthenticatedAIRequestAccess() async -> Bool {
        let hasToken = await tokenProvider.token() != nil
        let hasConsent = await dataUseConsentProvider.hasCurrentDataUseConsent()
        return hasToken && hasConsent
    }

    // MARK: - Non-streaming send

    /// Send a typed endpoint, retrying transient failures with exponential backoff.
    public func send<E: WorkerEndpoint>(
        _ endpoint: E
    ) async throws -> E.Response {
        
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
                    attempt: attempt
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
        attempt: Int
    ) async throws -> E.Response {
        
        do {
            return try await performAttempt(endpoint, attempt: attempt)
        } catch RishiError.unauthenticated {
            
            try await refreshAccessToken()
            
            return try await performAttempt(
                endpoint,
                attempt: attempt
            )
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
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1)) * 0.5))
            }
            do {
                return try await downloadAttempt(endpoint)
            } catch RishiError.unauthenticated {
                try await refreshAccessToken()
                return try await downloadAttempt(endpoint)
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

    private func downloadAttempt<E: WorkerStreamingEndpoint>(_ endpoint: E) async throws -> Data {
        let request = try await buildStreamingRequest(for: endpoint)
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
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw RishiError.unauthenticated }
            if let allowance = Self.decodeAllowanceError(from: data, status: http.statusCode) {
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
        
        AsyncThrowingStream { continuation in
            
            let task = Task {
                
                do {
                    
                    let request =
                    try await buildStreamingRequest(
                        for: endpoint
                    )
                    
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw RishiError.network(code: "invalid_response", message: "")
                    }

                    if http.statusCode == 401 {
                        try await refreshAccessToken()

                        let retry = try await buildStreamingRequest(for: endpoint)
                        let (retryBytes, retryResponse) = try await session.bytes(for: retry)
                        try await Self.consumeStreamingBody(
                            bytes: retryBytes,
                            response: retryResponse
                        ) { continuation.yield($0) }
                        continuation.finish()
                        return
                    }

                    try await Self.consumeStreamingBody(
                        bytes: bytes,
                        response: http
                    ) { continuation.yield($0) }
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
        yield: @escaping (Data) -> Void
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw RishiError.network(code: "invalid_response", message: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            if let allowance = Self.decodeAllowanceError(from: body, status: http.statusCode) {
                throw allowance
            }
            throw RishiError.network(code: "http_\(http.statusCode)", message: "")
        }

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4096 {
                yield(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            yield(buffer)
        }
    }

    private func performAttempt<E: WorkerEndpoint>(_ endpoint: E, attempt: Int) async throws -> E.Response {
        let request = try await buildRequest(for: endpoint)
    
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw RishiError.networkFailure(urlError)
        }

        _ = Int(Date().timeIntervalSince(started) * 1000)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1

  

        switch status {
        case 200..<300:
            do {
                return try decoder.decode(E.Response.self, from: data)
            } catch {
                throw RishiError.decoding("Failed to decode \(E.Response.self) at \(endpoint.path): \(error)")
            }
        case 401:
            throw RishiError.unauthenticated
        case 400..<500:
            if let allowance = Self.decodeAllowanceError(from: data, status: status) {
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

    private static func decodeAllowanceError(from data: Data, status: Int) -> WorkerAllowanceError? {
        guard status == 402,
              let flat = try? JSONDecoder().decode(FlatErrorEnvelope.self, from: data),
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
    private func refreshAccessToken() async throws {
        
        if let refreshTask {
            return try await refreshTask.value
        }
        
        let task = Task {
            try await actuallyRefresh()
        }
        
        refreshTask = task
        
        defer {
            refreshTask = nil
        }
        
        try await task.value
    }
 
    
    private func actuallyRefresh() async throws {
        
        guard let refreshToken =
                try Keychain.load(.refreshToken)
        else {
            throw RishiError.unauthenticated
        }
        
        var request = URLRequest(
            url: makeURL(path: "/auth/refresh")
        )
        
        request.httpMethod = "POST"
        
        request.httpShouldHandleCookies = false
        
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        
        struct Body: Encodable {
            let refreshToken: String
        }
        
        request.httpBody =
        try encoder.encode(
            Body(refreshToken: refreshToken)
        )
        
        let (data, response) =
        try await session.data(for: request)
        
        guard
            let http = response as? HTTPURLResponse
        else {
            throw RishiError.network(
                code: "invalid_response",
                message: ""
            )
        }
        
        guard http.statusCode == 200 else {
            
            Keychain.delete(.accessToken)
            Keychain.delete(.refreshToken)
            
            throw RishiError.unauthenticated
        }
        
        struct Tokens: Decodable {
            
            let accessToken: String
            let refreshToken: String
        }
        
        let tokens =
        try JSONDecoder().decode(
            Tokens.self,
            from: data
        )
        
        try Keychain.save(
            tokens.accessToken,
            for: .accessToken
        )
        
        try Keychain.save(
            tokens.refreshToken,
            for: .refreshToken
        )

        let sessionStore = KeychainSessionStore()
        if let currentSession = try? await sessionStore.load() {
            try await sessionStore.save(
                Session(
                    token: tokens.accessToken,
                    userId: currentSession.userId,
                    email: currentSession.email,
                    issuedAt: Date(),
                    expiresAt: currentSession.expiresAt
                )
            )
        }
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
        let url = makeURL(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Native bearer-token client: never attach or store cookies. Better Auth's
        // origin check only fires when a Cookie header is present, so a stray stored
        // session cookie would trip a 403 MISSING_OR_NULL_ORIGIN on Bearer requests.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await applyDataUseConsentHeaderIfNeeded(
            endpoint.requiresDataUseConsent,
            to: &request
        )

        if let token = await tokenProvider.token() {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        #if DEBUG
        if devBypassEnabled {
            request.setValue(devBypassSecret ?? "1", forHTTPHeaderField: "X-Dev-Bypass")
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
        return request
    }

    func buildStreamingRequest<E: WorkerStreamingEndpoint>(
        for endpoint: E
    ) async throws -> URLRequest {
        let url = makeURL(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Native bearer-token client: never attach/store cookies (see buildRequest).
        request.httpShouldHandleCookies = false
        try await applyDataUseConsentHeaderIfNeeded(
            endpoint.requiresDataUseConsent,
            to: &request
        )

        if let token = await tokenProvider.token() {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        #if DEBUG
        if devBypassEnabled {
            request.setValue(devBypassSecret ?? "1", forHTTPHeaderField: "X-Dev-Bypass")
        }
        #endif
        if let bodied = endpoint as? (any WorkerStreamingEndpointWithBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(bodied.body))
        }
        return request
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

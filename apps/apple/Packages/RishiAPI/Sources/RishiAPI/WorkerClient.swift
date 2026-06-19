import Foundation
import RishiCore
import RishiLogging

/// Single networking surface for the Rishi worker. Inject one `WorkerClient`
/// per app + per test; pass it around as `any Sendable`. The actor isolation
/// makes the retry + breadcrumb state safe under Swift 6 strict concurrency.
public actor WorkerClient {

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any TokenProvider
    private let devBypassEnabled: Bool
    private let devBypassSecret: String?

    /// Retry attempt cap (total, including the initial try). Phase 2 fixes this
    /// at 3 per requirement API-01; revisit if 5xx tail-latency becomes a problem.
    private let maxAttempts = 3

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenProvider: any TokenProvider,
        devBypassEnabled: Bool = false,
        devBypassSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.devBypassEnabled = devBypassEnabled
        self.devBypassSecret = devBypassSecret
    }

    // MARK: - Non-streaming send

    /// Send a typed endpoint, retrying transient failures with exponential backoff.
    public func send<E: WorkerEndpoint>(_ endpoint: E) async throws -> E.Response {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                let delaySeconds = pow(2.0, Double(attempt - 1)) * 0.5
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            do {
                return try await performAttempt(endpoint, attempt: attempt)
            } catch let error as RishiError {
                switch error {
                case .unauthenticated, .network, .decoding, .notFound, .subscription, .cancelled, .persistence:
                    // 4xx + decode + business errors: do not retry.
                    Log.error("worker.error", error: error)
                    throw error
                case .networkFailure(let urlError):
                    if isRetryable(urlError) && attempt < maxAttempts {
                        lastError = error
                        continue
                    }
                    Log.error("worker.error", error: error)
                    throw error
                }
            } catch {
                Log.error("worker.error", error: error)
                throw error
            }
        }
        // Unreachable, but the compiler can't prove it; throw the last error.
        throw lastError ?? RishiError.networkFailure(URLError(.unknown))
    }

    private func performAttempt<E: WorkerEndpoint>(_ endpoint: E, attempt: Int) async throws -> E.Response {
        let request = try await buildRequest(for: endpoint)
        Log.event("worker.request", level: .info, data: [
            "method": endpoint.method.rawValue,
            "path": endpoint.path,
            "attempt": String(attempt),
        ])
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw RishiError.networkFailure(urlError)
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1

        Log.event("worker.response", level: .info, data: [
            "status": String(status),
            "duration_ms": String(elapsedMs),
        ])

        switch status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(E.Response.self, from: data)
            } catch {
                throw RishiError.decoding("Failed to decode \(E.Response.self) at \(endpoint.path): \(error)")
            }
        case 401:
            throw RishiError.unauthenticated
        case 400..<500:
            let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))
                ?? ErrorEnvelope(error: .init(code: "http_4xx", message: "HTTP \(status)"))
            throw RishiError.network(code: envelope.code, message: envelope.message)
        case 500..<600:
            // Retry handled by caller via re-throw of networkFailure-equivalent.
            if attempt < maxAttempts {
                throw RishiError.networkFailure(URLError(.networkConnectionLost))
            }
            throw RishiError.network(code: "http_5xx", message: "HTTP \(status)")
        default:
            throw RishiError.network(code: "http_unknown", message: "HTTP \(status)")
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

    // MARK: - Streaming

    /// Stream raw `Data` chunks from a streaming endpoint (e.g. `/api/audio/speech`).
    /// The returned `AsyncThrowingStream` terminates with an error on transport failure
    /// or non-2xx status, and finishes cleanly when the worker closes the body.
    public nonisolated func stream<E: WorkerStreamingEndpoint>(
        _ endpoint: E
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            // KEEP: nonisolated wrapper; Task body runs off main and bridges
            // URLSession.bytes into the AsyncThrowingStream continuation.
            let task = Task {
                do {
                    let request = try await self.buildStreamingRequest(for: endpoint)
                    let (bytes, response) = try await self.session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 401 {
                            continuation.finish(throwing: RishiError.unauthenticated)
                        } else {
                            continuation.finish(throwing: RishiError.network(
                                code: "http_\(http.statusCode)",
                                message: "HTTP \(http.statusCode)"
                            ))
                        }
                        return
                    }
                    var buffer = Data()
                    let flushSize = 4096
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= flushSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch let urlError as URLError {
                    continuation.finish(throwing: RishiError.networkFailure(urlError))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

        if let token = await tokenProvider.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            request.httpBody = try JSONEncoder().encode(AnyEncodable(bodied.body))
        }
        return request
    }

    private func buildStreamingRequest<E: WorkerStreamingEndpoint>(
        for endpoint: E
    ) async throws -> URLRequest {
        let url = makeURL(path: endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        // Native bearer-token client: never attach/store cookies (see buildRequest).
        request.httpShouldHandleCookies = false

        if let token = await tokenProvider.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        #if DEBUG
        if devBypassEnabled {
            request.setValue(devBypassSecret ?? "1", forHTTPHeaderField: "X-Dev-Bypass")
        }
        #endif
        if let bodied = endpoint as? (any WorkerStreamingEndpointWithBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(bodied.body))
        }
        return request
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

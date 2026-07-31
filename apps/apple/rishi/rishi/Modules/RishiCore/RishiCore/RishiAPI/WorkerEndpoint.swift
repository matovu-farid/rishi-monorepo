import Foundation

/// Shared data-use consent request contract for remote content and AI calls.
public enum WorkerDataUseConsent {
    public static let headerField = "X-Rishi-Data-Use-Consent"
    public static let currentVersion = "2026-07-29"
}

/// Supplies the currently valid consent header value, if the signed-in user
/// has granted the current data-use consent.
public protocol WorkerDataUseConsentProvider: Sendable {
    func hasCurrentDataUseConsent() async -> Bool
}

public struct AlwaysAllowWorkerDataUseConsentProvider: WorkerDataUseConsentProvider {
    public init() {}
    public func hasCurrentDataUseConsent() async -> Bool { true }
}

public struct WorkerDataUseConsentRequiredError: Error, Sendable, Equatable {
    public init() {}
}

/// Default provider for tests, previews, and non-consent-aware clients.
public struct NoWorkerDataUseConsentProvider: WorkerDataUseConsentProvider {
    public init() {}

    public func hasCurrentDataUseConsent() async -> Bool { false }
}

/// HTTP verb used by a `WorkerEndpoint`.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case GET
    case POST
    case PUT
    case DELETE
    case PATCH
}

/// A typed worker endpoint. Plan 02-05 declares one conforming type per
/// endpoint in .planning/codebase/INTEGRATIONS.md; plan 02-04's `WorkerClient`
/// has a single generic `send<E: WorkerEndpoint>(_ endpoint: E) async throws -> E.Response`.
///
/// Bodies are declared by a sibling `WorkerEndpointWithBody` refinement plan
/// 02-05 will add — keeping the base protocol minimal so GET endpoints don't
/// have to satisfy a body requirement.
public protocol WorkerEndpoint: Sendable {
    /// Type returned to the caller after JSON-decoding the worker response.
    associatedtype Response: Decodable & Sendable

    /// HTTP method used for the request.
    var method: HTTPMethod { get }

    /// Path relative to `WorkerClient`'s `baseURL` (must start with `/`).
    var path: String { get }

    /// Whether this request carries remote content or AI-user data.
    var requiresDataUseConsent: Bool { get }
}

extension WorkerEndpoint {
    public var requiresDataUseConsent: Bool { false }
}

extension WorkerEndpoint {
    public func send() async throws -> Response {
        let baseURLString =
        ProcessInfo.processInfo.environment["RISHI_API_URL"]
        ?? "https://api.fidexa.org"
        let baseURL =
        URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!
        
        let keychain = KeychainSessionStore()
        
        let tokenProvider = RishiAuthTokenProvider(keychain: keychain)
        
        let workerClient = WorkerClient(
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            
        )
        return try await workerClient.send(self)
    }
}

// MARK: - Endpoints WITH a request body (POST/PUT/PATCH)

/// A worker endpoint that sends an Encodable body. Plan 02-05 uses this for
/// POST/PUT/PATCH endpoints. GET endpoints conform to the bare `WorkerEndpoint`
/// (no body requirement).
public protocol WorkerEndpointWithBody: WorkerEndpoint {
    associatedtype Body: Encodable & Sendable
    var body: Body { get }
}



// MARK: - Streaming endpoints (e.g. /api/audio/speech)

/// A worker endpoint that yields chunks of raw bytes over a streaming HTTP body.
/// Used by `/api/audio/speech` (MP3 chunks). The client surface is
/// `WorkerClient.stream<E>(_:) -> AsyncThrowingStream<Data, Error>`.
public protocol WorkerStreamingEndpoint: Sendable {
    var method: HTTPMethod { get }
    var path: String { get }
    var requiresDataUseConsent: Bool { get }
}

extension WorkerStreamingEndpoint {
    public var requiresDataUseConsent: Bool { false }
}

/// Refinement for streaming endpoints that also send an Encodable body
/// (the typical case — POST /api/audio/speech with {text, voice, speed}).
public protocol WorkerStreamingEndpointWithBody: WorkerStreamingEndpoint {
    associatedtype Body: Encodable & Sendable
    var body: Body { get }
}

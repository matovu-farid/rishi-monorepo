import Foundation

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
}

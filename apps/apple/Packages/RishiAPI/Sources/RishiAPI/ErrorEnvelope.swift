import Foundation

/// Decoded shape of a 4xx error response from the Rishi worker.
/// Wire format mirrors electron's IPC error convention enriched with a
/// structured envelope, per Phase 2 requirement API-03.
///
/// Wire JSON:
/// ```json
/// { "error": { "code": "forbidden", "message": "...", "details": { "reason": "..." } } }
/// ```
public struct ErrorEnvelope: Codable, Sendable, Hashable {
    public let error: Inner

    public struct Inner: Codable, Sendable, Hashable {
        public let code: String
        public let message: String
        public let details: [String: String]?

        public init(code: String, message: String, details: [String: String]? = nil) {
            self.code = code
            self.message = message
            self.details = details
        }
    }

    public init(error: Inner) {
        self.error = error
    }

    /// Convenience accessors so call sites don't have to drill through `.error.`.
    public var code: String    { error.code }
    public var message: String { error.message }
    public var details: [String: String]? { error.details }
}

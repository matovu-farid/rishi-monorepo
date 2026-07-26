import Foundation

public enum SubscriptionRequirement: String, Codable, Sendable, Hashable {
    case pro
}

public enum RishiError: Error, Sendable {
    case unauthenticated
    case networkFailure(URLError)
    case persistence(String)
    case notFound
    case subscription(SubscriptionRequirement)
    case cancelled
    /// 4xx response (except 401) with a decoded error envelope (code + message).
    /// `code` and `message` are flat strings so RishiCore stays Foundation-only.
    /// RishiAPI's `ErrorEnvelope` Codable struct converts to this case at throw time.
    case network(code: String, message: String)
    /// JSON decode failure when parsing a worker response (path or context as message).
    case decoding(String)
}

extension RishiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "You are not signed in."
        case .networkFailure(let urlError):
            return "Network error: \(urlError.localizedDescription)"
        case .persistence(let message):
            return "Storage error: \(message)"
        case .notFound:
            return "The requested item was not found."
        case .subscription(let requirement):
            return "This feature requires a \(requirement.rawValue) subscription."
        case .cancelled:
            return "The operation was cancelled."
        case .network(let code, let message):
            return "Server error (\(code)): \(message)"
        case .decoding(let message):
            return "Couldn't decode response: \(message)"
        }
    }
}

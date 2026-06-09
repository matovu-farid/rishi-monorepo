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
        }
    }
}

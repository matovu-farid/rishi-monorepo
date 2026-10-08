import Foundation

public struct EntitlementSyncResult: Sendable, Equatable {
    public let verified: Bool
    public let reason: String?
    public init(verified: Bool, reason: String? = nil) {
        self.verified = verified
        self.reason = reason
    }
}

public enum EntitlementSyncConfigurationError: Error {
    case workerClientUnavailable
}

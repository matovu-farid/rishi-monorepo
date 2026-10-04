import Foundation

/// Authority for intentional account-only local mutations, such as nil-book chat.
public struct AccountMutationPermit: Sendable, Hashable, Codable {
    public let ownerID: UserID
    public let accountGeneration: UInt64

    public init(ownerID: UserID, accountGeneration: UInt64) {
        self.ownerID = ownerID
        self.accountGeneration = accountGeneration
    }
}

public enum LocalMutationAuthority: Sendable, Hashable {
    case book(BookReadingPermit)
    case accountOnly(AccountMutationPermit)
}

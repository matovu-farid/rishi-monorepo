import Foundation

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let id: UserID
    public var email: String
    public var displayName: String?
    public var avatarURL: URL?
    public var hasPro: Bool
    public var createdAt: Date

    public init(
        id: UserID = UUID(),
        email: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        hasPro: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.hasPro = hasPro
        self.createdAt = createdAt
    }
}

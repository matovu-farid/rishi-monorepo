import Foundation

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let id: UserID
    public let email: String?
    public let name: String?
    


    public init(
        id: UserID = UUID(),
        email: String?,
        name: String? = nil,

    ) {
        self.id = id
        self.email = email
        self.name = name
    }
}

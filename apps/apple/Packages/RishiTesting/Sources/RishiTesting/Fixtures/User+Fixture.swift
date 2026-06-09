import Foundation
import RishiCore

extension User {
    public static func fixture(
        id: UserID = UUID(),
        email: String = "fixture@example.com",
        displayName: String? = "Fixture User",
        avatarURL: URL? = nil,
        hasPro: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> User {
        User(
            id: id,
            email: email,
            displayName: displayName,
            avatarURL: avatarURL,
            hasPro: hasPro,
            createdAt: createdAt
        )
    }
}

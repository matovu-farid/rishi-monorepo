
import Foundation


enum DeepLinkDestination: Hashable, Sendable {
    case authCallback(token: String)
    case shareRedeem(token: String)
    case openBook(BookID)
    case openConversation(ConversationID)
    case unknown
}

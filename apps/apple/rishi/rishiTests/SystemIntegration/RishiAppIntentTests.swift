import Foundation
import AppIntents
import Testing
@testable import rishi

@Suite("Rishi App Intents")
struct RishiAppIntentTests {
    @Test("private open intents require local device authentication")
    func openIntentAuthenticationPolicy() {
        #expect(OpenRishiBookIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(OpenRishiConversationIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }

    @Test("book entity exposes only lightweight searchable values")
    func bookEntityDisplay() {
        let entity = RishiBookEntity(id: UUID(), title: "Book", author: "Author")

        #expect(entity.title == "Book")
        #expect(entity.author == "Author")
        #expect(entity.displayRepresentation.title == "Book")
    }

    @Test("conversation query omits requested IDs that are not available")
    func conversationQueryOmitsMissingIDs() async throws {
        let conversation = RishiConversationEntity(id: UUID(), title: "A conversation")
        let query = RishiConversationEntityQuery(
            loadByIDs: { ids in ids.contains(conversation.id) ? [conversation] : [] },
            loadAll: { [conversation] }
        )

        #expect(try await query.entities(for: [UUID(), conversation.id]) == [conversation])
    }
}

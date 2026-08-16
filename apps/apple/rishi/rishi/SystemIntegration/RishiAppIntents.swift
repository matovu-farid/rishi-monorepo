import AppIntents
import Foundation

struct OpenRishiBookIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Book"
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Book")
    var target: RishiBookEntity

    init() {}

    func perform() async throws -> some IntentResult {
        let book = try await RishiAppIntentRuntime.loadBook(id: target.id)
        return .result(opensIntent: OpenURLIntent(RishiSpotlightURL.book(book.id)))
    }
}

struct OpenRishiConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Conversation")
    var target: RishiConversationEntity

    init() {}

    func perform() async throws -> some IntentResult {
        let conversation = try await RishiAppIntentRuntime.loadConversation(id: target.id)
        return .result(opensIntent: OpenURLIntent(RishiSpotlightURL.conversation(conversation.id)))
    }
}

struct RishiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: OpenRishiBookIntent(),
                phrases: ["Open a book in \(.applicationName)"],
                shortTitle: "Open Book",
                systemImageName: "book"
            )
            AppShortcut(
                intent: OpenRishiConversationIntent(),
                phrases: ["Open a conversation in \(.applicationName)"],
                shortTitle: "Open Conversation",
                systemImageName: "bubble.left.and.bubble.right"
            )
    }
}

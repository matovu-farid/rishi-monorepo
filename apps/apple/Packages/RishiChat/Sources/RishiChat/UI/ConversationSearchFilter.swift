import Foundation
import RishiCore

/// Pure search filter for the Conversations tab — easy to unit-test, no I/O,
/// no SwiftUI.
///
/// The caller (``ConversationsListViewModel``) is responsible for hydrating the
/// per-conversation message arrays. This filter just consumes them and returns
/// the matching conversations in ``Conversation/updatedAt`` descending order.
///
/// Matching is case-insensitive AND diacritic-insensitive (Finder/Spotlight
/// semantics): the needle "cafe" matches the haystack "Café".
enum ConversationSearchFilter {

    static func apply(
        conversations: [Conversation],
        messagesByConversation: [ConversationID: [Message]],
        query rawQuery: String
    ) -> [Conversation] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
        guard !trimmed.isEmpty else { return sorted }

        let needle = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )

        return sorted.filter { convo in
            // Title hit.
            let titleFolded = convo.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            if titleFolded.contains(needle) { return true }

            // Message-content hit (any message in this conversation).
            let messages = messagesByConversation[convo.id] ?? []
            return messages.contains { msg in
                msg.content
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .contains(needle)
            }
        }
    }
}

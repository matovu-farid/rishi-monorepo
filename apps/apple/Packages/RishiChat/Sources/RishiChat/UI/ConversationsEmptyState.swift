import SwiftUI
import RishiUIKit

/// CHAT-07 — empty-state UX on the Conversations tab.
///
/// Rendered when ``ConversationsListViewModel/conversations`` is empty AND the
/// user has not typed a search query (a non-empty query with zero results
/// shows a different "no results" branch handled by SwiftUI's `.searchable`).
struct ConversationsEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No conversations yet",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Open a book and tap the chat button to start a conversation about what you're reading.")
        )
        .foregroundStyle(RishiColor.textPrimary)
        .background(RishiColor.background)
    }
}

#Preview("Empty state") {
    ConversationsEmptyState()
}

#Preview("Empty state - dark") {
    ConversationsEmptyState()
        .preferredColorScheme(.dark)
}

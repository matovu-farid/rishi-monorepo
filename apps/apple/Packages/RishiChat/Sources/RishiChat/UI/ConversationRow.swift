import SwiftUI
import RishiCore
import RishiUIKit

/// One row in the Conversations tab list.
///
/// Title + a relative-time stamp + an optional "In book" badge if the
/// conversation is bound to a `bookId`. Visuals route through RishiUIKit
/// tokens — no hardcoded SwiftUI colors / sizes / paddings.
struct ConversationRow: View {

    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            Text(conversation.title)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textPrimary)
                .lineLimit(1)
            HStack(spacing: RishiSpacing.s) {
                if conversation.bookId != nil {
                    Label("In book", systemImage: "book.closed")
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                }
                Text(conversation.updatedAt, style: .relative)
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textSecondary)
            }
        }
        .padding(.vertical, RishiSpacing.xs)
        // Combine the title + metadata into one VoiceOver element. The
        // shared `A11yLabel.conversationRowOpen` keeps the verb consistent
        // with library + reader; the hint exposes the per-row title.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(A11yLabel.conversationRowOpen)
        .accessibilityHint(conversation.title)
    }
}

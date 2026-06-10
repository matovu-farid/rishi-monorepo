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

private enum ConversationRowPreviewFixtures {
    static func standalone() -> Conversation {
        Conversation(
            userId: UUID(),
            bookId: nil,
            title: "Reading list ideas for next quarter",
            createdAt: Date().addingTimeInterval(-RishiPreviewClock.hour),
            updatedAt: Date().addingTimeInterval(-RishiPreviewClock.minute * 5)
        )
    }

    static func inBook() -> Conversation {
        Conversation(
            userId: UUID(),
            bookId: UUID(),
            title: "Why does the protagonist hesitate at the bridge?",
            createdAt: Date().addingTimeInterval(-RishiPreviewClock.day),
            updatedAt: Date().addingTimeInterval(-RishiPreviewClock.minute)
        )
    }
}

private enum RishiPreviewClock {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 60 * 60
    static let day: TimeInterval = 60 * 60 * 24
}

#Preview("Row - standalone") {
    List {
        ConversationRow(conversation: ConversationRowPreviewFixtures.standalone())
    }
    .listStyle(.plain)
}

#Preview("Row - in book") {
    List {
        ConversationRow(conversation: ConversationRowPreviewFixtures.inBook())
    }
    .listStyle(.plain)
}

#Preview("Row - dark") {
    List {
        ConversationRow(conversation: ConversationRowPreviewFixtures.standalone())
        ConversationRow(conversation: ConversationRowPreviewFixtures.inBook())
    }
    .listStyle(.plain)
    .preferredColorScheme(.dark)
}

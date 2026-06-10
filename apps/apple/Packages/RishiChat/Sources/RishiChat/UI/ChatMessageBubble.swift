import SwiftUI
import RishiCore
import RishiUIKit

/// One message in the chat transcript.
///
/// User messages align trailing on an accent-tinted bubble; assistant messages
/// align leading on an elevated-surface bubble. All visuals route through
/// RishiUIKit tokens — no SwiftUI built-in colors, no `.padding(<Int>)`, no
/// `.system(size:)` literals.
struct ChatMessageBubble: View {

    let message: Message

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user {
                Spacer(minLength: RishiSpacing.l)
            }

            Text(message.content)
                .font(RishiTypography.body)
                .foregroundStyle(textColor)
                .padding(.vertical, RishiSpacing.s)
                .padding(.horizontal, RishiSpacing.m)
                .background(
                    bubbleColor,
                    in: RoundedRectangle(cornerRadius: RishiRadius.medium, style: .continuous)
                )

            if message.role == .assistant {
                Spacer(minLength: RishiSpacing.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        // Collapse the bubble into a single VoiceOver element labelled
        // with role + content so screen readers don't read the spacers,
        // background shape, or text fragments separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(roleLabel): \(message.content)")
    }

    private var roleLabel: String {
        switch message.role {
        case .user:      return "You"
        case .assistant: return "Assistant"
        case .system:    return "System"
        }
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:      return RishiColor.accent
        case .assistant: return RishiColor.surfaceElevated
        case .system:    return RishiColor.surfaceElevated
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user:
            // Light-on-accent contrast pair. RishiUIKit has no dedicated
            // `onAccent` token in Phase 1; `.background` is the semantic
            // light surface and reads correctly on top of the accent fill.
            return RishiColor.background
        case .assistant, .system:
            return RishiColor.textPrimary
        }
    }
}

private enum ChatMessageBubblePreviewFixtures {
    static let conversationId = UUID()

    static func user(_ text: String) -> Message {
        Message(conversationId: conversationId, role: .user, content: text)
    }

    static func assistant(_ text: String) -> Message {
        Message(conversationId: conversationId, role: .assistant, content: text)
    }

    static let longUserPrompt: String = """
    I have been reading this chapter for the third time now and I keep tripping on the metaphor about the river. \
    Can you walk me through what the author is really getting at, and how it connects to the earlier theme about \
    the protagonist's relationship with their grandfather?
    """

    static let longAssistantReply: String = """
    The river functions as a stand-in for inherited memory. Each time the protagonist visits its banks, the prose \
    deliberately echoes phrases used to describe their grandfather in chapter two — the same verbs, the same \
    cadence. That repetition is the connective tissue: the author is saying that the past is not behind us, it is \
    a current we keep wading into. The grandfather did not just shape the protagonist's childhood; he laid the \
    riverbed they are still standing in.
    """

    static let streamingPartial = "Sure — the symbol of the river maps onto inherited memory, and the prose echo"
}

#Preview("Bubble - user") {
    ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.user("What's the central metaphor in chapter three?"))
        .padding(RishiSpacing.m)
        .background(RishiColor.background)
}

#Preview("Bubble - assistant") {
    ChatMessageBubble(
        message: ChatMessageBubblePreviewFixtures.assistant(
            "Chapter three returns to the river — it stands in for inherited memory."
        )
    )
    .padding(RishiSpacing.m)
    .background(RishiColor.background)
}

#Preview("Bubble - streaming partial") {
    ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.assistant(ChatMessageBubblePreviewFixtures.streamingPartial))
        .padding(RishiSpacing.m)
        .background(RishiColor.background)
}

#Preview("Bubble - long messages") {
    ScrollView {
        VStack(alignment: .leading, spacing: RishiSpacing.s) {
            ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.user(ChatMessageBubblePreviewFixtures.longUserPrompt))
            ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.assistant(ChatMessageBubblePreviewFixtures.longAssistantReply))
        }
        .padding(RishiSpacing.m)
    }
    .background(RishiColor.background)
}

#Preview("Bubble - dark mode") {
    VStack(alignment: .leading, spacing: RishiSpacing.s) {
        ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.user("How long is this book?"))
        ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.assistant("Roughly 412 pages in the paperback edition."))
        ChatMessageBubble(message: ChatMessageBubblePreviewFixtures.assistant(ChatMessageBubblePreviewFixtures.streamingPartial))
    }
    .padding(RishiSpacing.m)
    .background(RishiColor.background)
    .preferredColorScheme(.dark)
}

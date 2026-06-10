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

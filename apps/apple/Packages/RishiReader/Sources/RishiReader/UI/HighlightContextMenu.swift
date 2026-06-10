import SwiftUI
import RishiCore
import RishiUIKit

/// Floating context menu shown above a text selection (or above an existing
/// highlight when tapped). Renders the 4 color swatches + "Add Note" + an
/// optional "Delete" affordance.
///
/// Layout uses RishiSpacing / RishiRadius / RishiColor tokens — never literal
/// padding or hex. Color circles route through
/// ``HighlightColor.swiftUIColor`` so the swatches match what the overlay
/// will paint when the user picks one.
public struct HighlightContextMenu: View {

    public let onColor: (HighlightColor) -> Void
    public let onAddNote: () -> Void
    /// Pass `nil` to hide the trash affordance (e.g. for a brand-new
    /// selection that hasn't been saved yet).
    public let onDelete: (() -> Void)?
    /// Plan 09-06 (CHAT-05) — when non-nil, surfaces an "Ask about this"
    /// affordance that opens the chat sheet with the selection text
    /// prefilled as a quote. Nil hides the button.
    public let onAskAboutThis: (() -> Void)?

    public init(
        onColor: @escaping (HighlightColor) -> Void,
        onAddNote: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onAskAboutThis: (() -> Void)? = nil
    ) {
        self.onColor = onColor
        self.onAddNote = onAddNote
        self.onDelete = onDelete
        self.onAskAboutThis = onAskAboutThis
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.s) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button(action: { onColor(color) }) {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(RishiColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("highlight.color.\(color.rawValue)")
                .accessibilityLabel("\(A11yLabel.readerHighlightColor) \(color.rawValue)")
            }
            Button(action: onAddNote) {
                Image(systemName: "note.text")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textPrimary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("highlight.addNote")
            .accessibilityLabel(A11yLabel.readerAddNote)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.danger)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("highlight.delete")
                .accessibilityLabel(A11yLabel.readerDeleteHighlight)
            }

            if let onAskAboutThis {
                Button(action: onAskAboutThis) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("highlight-ask-about-this")
                .accessibilityLabel("Ask about this")
            }
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.vertical, RishiSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: RishiRadius.medium)
                .fill(RishiColor.surface)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
    }
}

#Preview("New selection") {
    HighlightContextMenu(
        onColor: { _ in },
        onAddNote: {}
    )
    .padding(RishiSpacing.xxl)
    .background(RishiColor.readerBackgroundLight)
}

#Preview("Existing with delete") {
    HighlightContextMenu(
        onColor: { _ in },
        onAddNote: {},
        onDelete: {}
    )
    .padding(RishiSpacing.xxl)
    .background(RishiColor.readerBackgroundSepia)
}

#Preview("Ask about this") {
    HighlightContextMenu(
        onColor: { _ in },
        onAddNote: {},
        onDelete: {},
        onAskAboutThis: {}
    )
    .padding(RishiSpacing.xxl)
    .background(RishiColor.readerBackgroundDark)
}

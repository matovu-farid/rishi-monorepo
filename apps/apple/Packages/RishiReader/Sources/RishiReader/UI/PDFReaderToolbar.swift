import SwiftUI
import RishiUIKit

/// Top chrome row for the PDF reader: close button + book title +
/// optional TOC + theme actions.
///
/// `onTOC` and `onTheme` are optional — when nil, the buttons are hidden so
/// older call sites (tests, previews) keep working without sheet plumbing.
public struct PDFReaderToolbar: View {
    public let title: String
    public let onClose: () -> Void
    public let onTOC: (() -> Void)?
    public let onTheme: (() -> Void)?
    public let onReadAloud: (() -> Void)?
    /// Plan 09-06 (CHAT-01) — when non-nil, surfaces a chat button that
    /// asks the injected `ReaderChatPresenter` to open the chat sheet for
    /// the active book. Nil hides the button so older call sites (tests,
    /// previews, future readers that opt out) keep working.
    public let onChat: (() -> Void)?

    public init(
        title: String,
        onClose: @escaping () -> Void,
        onTOC: (() -> Void)? = nil,
        onTheme: (() -> Void)? = nil,
        onReadAloud: (() -> Void)? = nil,
        onChat: (() -> Void)? = nil
    ) {
        self.title = title
        self.onClose = onClose
        self.onTOC = onTOC
        self.onTheme = onTheme
        self.onReadAloud = onReadAloud
        self.onChat = onChat
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.m) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close reader")

            Text(title)
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onTOC {
                Button(action: onTOC) {
                    Image(systemName: "list.bullet.indent")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Table of contents")
            }

            if let onTheme {
                Button(action: onTheme) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Reader theme")
            }

            if let onReadAloud {
                Button(action: onReadAloud) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader-read-aloud")
                .accessibilityLabel("Read Aloud")
            }

            if let onChat {
                Button(action: onChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader-chat")
                .accessibilityLabel("Chat about this book")
            }
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surface.opacity(0.85))
    }
}

import SwiftUI
import RishiUIKit

/// Top chrome row for the PDF reader: book title + optional TOC + theme
/// actions. The system NavigationStack chevron (top-left) provides
/// dismissal — there is no in-app close button. See F-P0-02 in
/// `apps/apple/.planning/phases/18-native-swiftui-audit-and-migration-sweep-for-the-ios-app/18-RESEARCH.md`.
///
/// `onTOC` and `onTheme` are optional — when nil, the buttons are hidden so
/// older call sites (tests, previews) keep working without sheet plumbing.
public struct PDFReaderToolbar: View {
    public let title: String
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
        onTOC: (() -> Void)? = nil,
        onTheme: (() -> Void)? = nil,
        onReadAloud: (() -> Void)? = nil,
        onChat: (() -> Void)? = nil
    ) {
        self.title = title
        self.onTOC = onTOC
        self.onTheme = onTheme
        self.onReadAloud = onReadAloud
        self.onChat = onChat
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.m) {
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
                .accessibilityIdentifier("reader.toolbar.toc")
                .accessibilityLabel(A11yLabel.readerOpenTOC)
            }

            if let onTheme {
                Button(action: onTheme) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader.toolbar.theme")
                .accessibilityLabel(A11yLabel.readerOpenTheme)
            }

            if let onReadAloud {
                Button(action: onReadAloud) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader.toolbar.readAloud")
                .accessibilityLabel(A11yLabel.readerReadAloud)
            }

            if let onChat {
                Button(action: onChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(RishiTypography.bodyEmphasized)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("reader.toolbar.chat")
                .accessibilityLabel(A11yLabel.readerOpenChat)
            }
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surface.opacity(0.85))
    }
}

#Preview("Title only") {
    VStack {
        PDFReaderToolbar(
            title: "Alice's Adventures in Wonderland"
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundLight)
}

#Preview("TOC and theme") {
    VStack {
        PDFReaderToolbar(
            title: "The Pragmatic Programmer",
            onTOC: {},
            onTheme: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundLight)
}

#Preview("All actions") {
    VStack {
        PDFReaderToolbar(
            title: "Designing Data-Intensive Applications",
            onTOC: {},
            onTheme: {},
            onReadAloud: {},
            onChat: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundSepia)
}

#Preview("Long title truncation") {
    VStack {
        PDFReaderToolbar(
            title: "A Very Long Book Title That Should Be Truncated With Ellipsis At The End",
            onTOC: {},
            onTheme: {},
            onReadAloud: {},
            onChat: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundDark)
}

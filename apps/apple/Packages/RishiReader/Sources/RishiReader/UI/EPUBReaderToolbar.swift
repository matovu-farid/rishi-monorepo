import SwiftUI
import RishiUIKit

/// Top chrome row for the EPUB reader: book title + Contents + Typography
/// + Theme buttons. The system NavigationStack chevron (top-left) provides
/// dismissal — there is no in-app close button. See F-P0-02 in
/// `apps/apple/.planning/phases/18-native-swiftui-audit-and-migration-sweep-for-the-ios-app/18-RESEARCH.md`.
///
/// The TOC / theme / typography buttons fire closures; the screen mounts
/// the corresponding sheets in 06-06. While the publication is loading
/// (`isPublicationLoaded == false`) the discovery buttons are disabled
/// so users can't trigger sheets that have nothing to render.
public struct EPUBReaderToolbar: View {

    public let title: String
    public let isPublicationLoaded: Bool
    public let onShowTOC: () -> Void
    public let onShowTheme: () -> Void
    public let onShowTypography: () -> Void
    public let onReadAloud: (() -> Void)?
    /// Plan 09-06 (CHAT-01) — when non-nil, surfaces a chat button that
    /// asks the injected `ReaderChatPresenter` to open the chat sheet for
    /// the active book. Nil hides the button so older call sites (tests,
    /// previews) keep working.
    public let onChat: (() -> Void)?

    public init(
        title: String,
        isPublicationLoaded: Bool,
        onShowTOC: @escaping () -> Void,
        onShowTheme: @escaping () -> Void,
        onShowTypography: @escaping () -> Void,
        onReadAloud: (() -> Void)? = nil,
        onChat: (() -> Void)? = nil
    ) {
        self.title = title
        self.isPublicationLoaded = isPublicationLoaded
        self.onShowTOC = onShowTOC
        self.onShowTheme = onShowTheme
        self.onShowTypography = onShowTypography
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

            iconButton(
                "list.bullet.indent",
                label: A11yLabel.readerOpenTOC,
                a11yId: "reader.toolbar.toc",
                action: onShowTOC
            )
            .disabled(!isPublicationLoaded)
            iconButton(
                "textformat.size",
                label: A11yLabel.readerOpenTypography,
                a11yId: "reader.toolbar.typography",
                action: onShowTypography
            )
            .disabled(!isPublicationLoaded)
            iconButton(
                "circle.lefthalf.filled",
                label: A11yLabel.readerOpenTheme,
                a11yId: "reader.toolbar.theme",
                action: onShowTheme
            )
            .disabled(!isPublicationLoaded)
            if let onReadAloud {
                iconButton(
                    "speaker.wave.2.fill",
                    label: A11yLabel.readerReadAloud,
                    a11yId: "reader.toolbar.readAloud",
                    action: onReadAloud
                )
                .disabled(!isPublicationLoaded)
            }
            if let onChat {
                iconButton(
                    "bubble.left.and.bubble.right",
                    label: A11yLabel.readerOpenChat,
                    a11yId: "reader.toolbar.chat",
                    action: onChat
                )
                .disabled(!isPublicationLoaded)
            }
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surfaceElevated.opacity(0.85))
    }

    @ViewBuilder
    private func iconButton(
        _ systemName: String,
        label: String,
        a11yId: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textPrimary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(a11yId ?? "")
    }
}

#Preview("Loading") {
    VStack {
        EPUBReaderToolbar(
            title: "Loading…",
            isPublicationLoaded: false,
            onShowTOC: {},
            onShowTheme: {},
            onShowTypography: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundLight)
}

#Preview("Loaded") {
    VStack {
        EPUBReaderToolbar(
            title: "Alice's Adventures in Wonderland",
            isPublicationLoaded: true,
            onShowTOC: {},
            onShowTheme: {},
            onShowTypography: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundLight)
}

#Preview("Read aloud and chat") {
    VStack {
        EPUBReaderToolbar(
            title: "Pride and Prejudice",
            isPublicationLoaded: true,
            onShowTOC: {},
            onShowTheme: {},
            onShowTypography: {},
            onReadAloud: {},
            onChat: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundSepia)
}

#Preview("Long title truncation") {
    VStack {
        EPUBReaderToolbar(
            title: "A Very Long Book Title That Should Be Truncated With Ellipsis",
            isPublicationLoaded: true,
            onShowTOC: {},
            onShowTheme: {},
            onShowTypography: {},
            onReadAloud: {},
            onChat: {}
        )
        Spacer()
    }
    .background(RishiColor.readerBackgroundDark)
}

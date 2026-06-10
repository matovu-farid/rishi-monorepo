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

    public init(
        title: String,
        onClose: @escaping () -> Void,
        onTOC: (() -> Void)? = nil,
        onTheme: (() -> Void)? = nil
    ) {
        self.title = title
        self.onClose = onClose
        self.onTOC = onTOC
        self.onTheme = onTheme
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
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surface.opacity(0.85))
    }
}

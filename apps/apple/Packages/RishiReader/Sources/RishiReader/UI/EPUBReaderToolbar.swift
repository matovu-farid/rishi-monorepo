import SwiftUI
import RishiUIKit

/// Top chrome row for the EPUB reader: close + book title + Contents +
/// Typography + Theme buttons.
///
/// The TOC / theme / typography buttons fire closures; the screen mounts
/// the corresponding sheets in 06-06. While the publication is loading
/// (`isPublicationLoaded == false`) the discovery buttons are disabled
/// so users can't trigger sheets that have nothing to render.
public struct EPUBReaderToolbar: View {

    public let title: String
    public let isPublicationLoaded: Bool
    public let onClose: () -> Void
    public let onShowTOC: () -> Void
    public let onShowTheme: () -> Void
    public let onShowTypography: () -> Void

    public init(
        title: String,
        isPublicationLoaded: Bool,
        onClose: @escaping () -> Void,
        onShowTOC: @escaping () -> Void,
        onShowTheme: @escaping () -> Void,
        onShowTypography: @escaping () -> Void
    ) {
        self.title = title
        self.isPublicationLoaded = isPublicationLoaded
        self.onClose = onClose
        self.onShowTOC = onShowTOC
        self.onShowTheme = onShowTheme
        self.onShowTypography = onShowTypography
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.m) {
            iconButton("xmark", label: "Close reader", action: onClose)

            Text(title)
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            iconButton("list.bullet.indent", label: "Table of contents", action: onShowTOC)
                .disabled(!isPublicationLoaded)
            iconButton("textformat.size", label: "Typography", action: onShowTypography)
                .disabled(!isPublicationLoaded)
            iconButton("circle.lefthalf.filled", label: "Reader theme", action: onShowTheme)
                .disabled(!isPublicationLoaded)
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surfaceElevated.opacity(0.85))
    }

    @ViewBuilder
    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textPrimary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

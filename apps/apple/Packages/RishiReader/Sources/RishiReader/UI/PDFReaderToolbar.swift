import SwiftUI
import RishiUIKit

/// Top chrome row for the PDF reader: close button + book title.
///
/// More controls (TOC sheet button, theme picker, highlight palette) layer
/// in via plans 05-06 / 05-07. This plan ships the dismiss affordance only
/// so the surface is reachable end-to-end.
public struct PDFReaderToolbar: View {
    public let title: String
    public let onClose: () -> Void

    public init(title: String, onClose: @escaping () -> Void) {
        self.title = title
        self.onClose = onClose
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
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.top, RishiSpacing.s)
        .background(RishiColor.surface.opacity(0.85))
    }
}

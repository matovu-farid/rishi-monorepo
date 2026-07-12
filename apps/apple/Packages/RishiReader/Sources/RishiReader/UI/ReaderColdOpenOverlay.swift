import SwiftUI
import RishiUIKit

/// Phase 21 Plan 21-03 — native SwiftUI overlay shown while a reader
/// view-model's `load()` is still resolving the document / publication.
/// Uses stock `ProgressView` per the Phase 18 native-UI rule; the book
/// title is the only customisation. SwiftUI gates the spinner on Reduce
/// Motion automatically — no manual handling required. Shared by
/// `PDFReaderScreen` and `ReaderScreen`.
struct ReaderColdOpenOverlay: View {
    let bookTitle: String
    var body: some View {
        ZStack {
            RishiColor.background.opacity(0.95).ignoresSafeArea()
            VStack(spacing: RishiSpacing.m) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                Text("Opening \(bookTitle)")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(bookTitle)")
    }
}

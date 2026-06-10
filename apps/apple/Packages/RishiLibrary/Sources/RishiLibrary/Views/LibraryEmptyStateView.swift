import SwiftUI
import RishiUIKit

#if canImport(UIKit)
import UIKit
#endif

/// LIB-09: empty-state shown when the user has zero books. Provides
/// per-platform copy explaining HOW to import a book.
///
/// The hero glyph uses `RishiTypography.titleXL` plus `.imageScale(.large)`
/// so it scales with Dynamic Type (A11Y-02) — no fixed point size.
public struct LibraryEmptyStateView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            Image(systemName: "books.vertical")
                .font(RishiTypography.titleXL)
                .imageScale(.large)
                .foregroundStyle(RishiColor.textMuted)
                .accessibilityHidden(true)
            Text("Your library is empty")
                .font(RishiTypography.titleL)
                .foregroundStyle(RishiColor.textPrimary)
            Text(importInstructions)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RishiSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.background)
    }

    private var importInstructions: String {
        #if targetEnvironment(macCatalyst)
        return "Drag an EPUB or PDF from Finder onto the window, or use File then Open."
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "Open Files, share an EPUB or PDF to Rishi, or drag a book onto the library."
        } else {
            return "Open Files or use the Share Sheet from Safari, Mail, or any app to send an EPUB or PDF to Rishi."
        }
        #else
        return "Open Files or share an EPUB or PDF to Rishi."
        #endif
    }
}

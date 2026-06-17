//
//  PDFViewModeSection.swift
//  RishiSettings (Phase 31 plan 31-04)
//
//  Mac-only Settings picker for the PDF view-mode preference (Automatic /
//  Single Page / Continuous / Two Page). The entire Section body is gated on
//  `#if targetEnvironment(macCatalyst)` so the control NEVER appears on iOS
//  (LOCKED scope, 31-RESEARCH.md Pitfall 3) — iOS renders `EmptyView`.
//
//  Mirrors `ReaderDefaultsSection`'s Picker-over-CaseIterable shape. Bound to
//  `AppReaderDefaults.pdfViewMode` via a Binding threaded down from
//  `SettingsScreen` / `SettingsSheet`.
//

import SwiftUI
import RishiUIKit
import RishiReader

struct PDFViewModeSection: View {

    @Binding private var selection: PDFViewModeSetting

    public init(selection: Binding<PDFViewModeSetting>) {
        self._selection = selection
    }

    public var body: some View {
        #if targetEnvironment(macCatalyst)
        Section {
            Picker("PDF View Mode", selection: $selection) {
                ForEach(PDFViewModeSetting.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings-pdf-view-mode")
        } header: {
            Text("PDF View Mode")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        } footer: {
            Text("Automatic uses Continuous when windowed and Two Page in full screen. Applies to open PDFs without reopening.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
        #else
        EmptyView()
        #endif
    }
}

private struct PDFViewModeSectionPreviewHost: View {
    @State private var selection: PDFViewModeSetting = .automatic

    var body: some View {
        Form {
            PDFViewModeSection(selection: $selection)
        }
    }
}

#Preview("Light") {
    PDFViewModeSectionPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    PDFViewModeSectionPreviewHost()
        .preferredColorScheme(.dark)
}

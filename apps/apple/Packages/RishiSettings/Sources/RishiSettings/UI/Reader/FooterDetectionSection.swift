//
//  FooterDetectionSection.swift
//  RishiSettings (Phase 27 plan 27-06)
//
//  Settings → Indexing section that toggles whether `PdfTextExtractor` runs
//  Phase 27's `FooterMaskBuilder` to drop recurring page numbers, running
//  titles, and footnote blocks from PDFs before chunking for RAG embedding.
//
//  EPUB indexing is unaffected (no positional chrome to detect). Per Phase 27
//  R3, the toggle does NOT touch the TTS path — `ParagraphChunker.chunk(_:)`
//  output stays byte-stable so the Phase 22 sha256 + Phase 24 paragraph
//  audio caches remain valid.
//

import SwiftUI
import RishiUIKit

struct FooterDetectionSection: View {

    let store: any FooterDetectionStore

    // Initial value chosen to match the production default so the toggle
    // doesn't visibly flicker between false/true on first render before
    // `.task` resolves the actual stored value.
    @State private var enabled: Bool = true

    public init(store: any FooterDetectionStore) {
        self.store = store
    }

    public var body: some View {
        Section {
            Toggle("Skip page footers when indexing", isOn: $enabled)
                .accessibilityIdentifier("settings-footer-detection")
                .onChange(of: enabled) { _, new in
                    Task { await store.setSkipPageFootersWhenIndexing(new) }
                }
        } header: {
            Text("Indexing")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        } footer: {
            Text("Detects recurring page numbers, running titles, and footnote blocks in PDFs and omits them from search indexing. EPUB indexing is unaffected.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
        .task { enabled = await store.skipPageFootersWhenIndexing() }
    }
}

private struct FooterDetectionSectionPreviewHost: View {
    let store: any FooterDetectionStore = InMemoryFooterDetectionStore(initial: true)

    var body: some View {
        Form {
            FooterDetectionSection(store: store)
        }
    }
}

#Preview("Light") {
    FooterDetectionSectionPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    FooterDetectionSectionPreviewHost()
        .preferredColorScheme(.dark)
}

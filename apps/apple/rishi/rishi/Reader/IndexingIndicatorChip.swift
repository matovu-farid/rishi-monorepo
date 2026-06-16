//
//  IndexingIndicatorChip.swift
//  rishi
//
//  WS4 — low-salience indexing progress chip. Polls the on-device RAG index
//  status for a book while it is building and renders a small caption-style
//  pill. Hidden whenever `BookSearchStatus.indicatorText` is nil (i.e. the
//  index is not yet started, ready, or failed) so the reader stays uncluttered.
//
//  Lives in the app target (not RishiReader) so it can pair RishiSearch's
//  `BookSearch` facade with the app's `GlassCardBackground` material without
//  making RishiReader depend on RishiSearch.
//

import SwiftUI
import RishiCore
import RishiSearch
import RishiUIKit

struct IndexingIndicatorChip: View {
    let bookId: BookID
    let bookSearch: any BookSearch

    /// Latest observed status. Starts `.notIndexed` so the poll loop runs at
    /// least once on appear; the view renders nothing until the status becomes
    /// `.indexing` (the only case with non-nil `indicatorText`).
    @State private var status: BookSearchStatus = .notIndexed

    var body: some View {
        Group {
            if let text = status.indicatorText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, RishiSpacing.s)
                    .padding(.vertical, RishiSpacing.xs)
                    .modifier(GlassCardBackground(cornerRadius: RishiRadius.medium))
                    .padding(.horizontal, RishiSpacing.m)
                    .padding(.bottom, RishiSpacing.s)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status.indicatorText)
        .task(id: bookId) {
            // Poll while the index is forming. `.ready`/`.failed` are terminal
            // for this screen — stop polling so we don't spin a 1s timer for
            // the reader's whole lifetime.
            //
            // Defense-in-depth: a persistent `.notIndexed` (no sidecar) would
            // otherwise loop forever (battery/CPU drain, no UI). Cap consecutive
            // `.notIndexed` reads and stop polling once we hit it. `.indexing`
            // means real progress, so it resets the counter. (Bug-2's fix makes
            // a failed build land on `.failed` promptly; this guards any other
            // stuck-`.notIndexed`.)
            let maxConsecutiveNotIndexed = 10
            var consecutiveNotIndexed = 0
            while !Task.isCancelled {
                let current = await bookSearch.status(bookId: bookId)
                status = current
                switch current {
                case .ready, .failed:
                    return
                case .indexing:
                    consecutiveNotIndexed = 0
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                case .notIndexed:
                    consecutiveNotIndexed += 1
                    if consecutiveNotIndexed >= maxConsecutiveNotIndexed {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}

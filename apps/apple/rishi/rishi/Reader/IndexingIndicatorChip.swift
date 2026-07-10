













import SwiftUI
import RishiCore
import RishiSearch
import RishiUIKit

struct IndexingIndicatorChip: View {
    let bookId: BookID
    let bookSearch: any BookSearch

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
            while !Task.isCancelled {
                let current = await bookSearch.status(bookId: bookId)
                status = current
                switch current {
                case .ready, .failed, .staleIndexing:
                    return
                case .indexing:
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                case .notIndexed:
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}

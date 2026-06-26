













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

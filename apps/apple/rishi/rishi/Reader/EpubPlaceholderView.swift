
import SwiftUI
import RishiCore


struct EpubPlaceholderView: View {
    let book: Book
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                Text(book.title)
                    .font(.title3)
                Text("MOBI / AZW3 aren't supported yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

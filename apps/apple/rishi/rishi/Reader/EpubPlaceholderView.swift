//
//  EpubPlaceholderView.swift
//  rishi
//

import SwiftUI
import RishiCore

/// Catches `.mobi` / `.azw3` taps — those formats need a converter step
/// that isn't on the v1 milestone. Shipped here so the library never
/// silently no-ops when the user taps an unsupported book.
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

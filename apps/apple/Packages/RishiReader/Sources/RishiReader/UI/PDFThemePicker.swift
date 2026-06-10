import SwiftUI
import RishiCore
import RishiUIKit

/// Sheet that lets the user pick a `ReaderTheme` for the current book.
///
/// Two-way binds the live theme (so the reader background re-renders
/// immediately) and writes through `ReaderSettingsStore` so the choice
/// survives close + reopen. The store key is the per-book BookID so
/// every book remembers its own theme.
public struct PDFThemePicker: View {

    @Binding public var theme: ReaderTheme
    public let bookId: BookID
    public let store: any ReaderSettingsStore
    public let onClose: () -> Void

    public init(
        theme: Binding<ReaderTheme>,
        bookId: BookID,
        store: any ReaderSettingsStore,
        onClose: @escaping () -> Void
    ) {
        self._theme = theme
        self.bookId = bookId
        self.store = store
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: RishiSpacing.m) {
                ForEach(ReaderTheme.allCases, id: \.self) { option in
                    Button(action: { select(option) }) {
                        HStack {
                            Circle()
                                .fill(swatch(for: option))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().stroke(RishiColor.divider, lineWidth: 1))
                            Text(label(for: option))
                                .font(RishiTypography.body)
                                .foregroundStyle(RishiColor.textPrimary)
                            Spacer()
                            if option == theme {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(RishiColor.accent)
                            }
                        }
                        .padding(.vertical, RishiSpacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(RishiSpacing.m)
            .navigationTitle("Theme")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private func select(_ option: ReaderTheme) {
        theme = option
        let bookId = self.bookId
        let store = self.store
        Task { await store.setTheme(option, for: bookId) }
    }

    private func swatch(for theme: ReaderTheme) -> Color {
        switch theme {
        case .light: return RishiColor.readerBackgroundLight
        case .sepia: return RishiColor.readerBackgroundSepia
        case .dark:  return RishiColor.readerBackgroundDark
        }
    }

    private func label(for theme: ReaderTheme) -> String {
        switch theme {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark:  return "Dark"
        }
    }
}

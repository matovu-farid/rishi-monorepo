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
        // KEEP: store is an actor backed by GRDB; the `await` already hops
        // off MainActor for the persist. Phase 20 revert of gratuitous
        // `Task.detached` — see SWIFT-CONCURRENCY-RULES.md Pattern A.
        Task { await store.setTheme(option, for: bookId) }
    }

    private func swatch(for theme: ReaderTheme) -> Color {
        switch theme {
        case .matchDevice: return Color.primary.opacity(0.35)
        case .light: return RishiColor.readerBackgroundLight
        case .sepia: return RishiColor.readerBackgroundSepia
        case .dark:  return RishiColor.readerBackgroundDark
        }
    }

    private func label(for theme: ReaderTheme) -> String {
        switch theme {
        case .matchDevice: return "Match Device"
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark:  return "Dark"
        }
    }
}

private final class PreviewSettingsStore: ReaderSettingsStore, Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { }
    func typography(for bookId: BookID) async -> ReaderTypography { .default }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { }
}

private struct PDFThemePickerPreviewHost: View {
    @State var theme: ReaderTheme
    var body: some View {
        PDFThemePicker(
            theme: $theme,
            bookId: UUID(),
            store: PreviewSettingsStore(),
            onClose: {}
        )
    }
}

#Preview("Light selected") {
    PDFThemePickerPreviewHost(theme: .light)
}

#Preview("Sepia selected") {
    PDFThemePickerPreviewHost(theme: .sepia)
}

#Preview("Dark selected") {
    PDFThemePickerPreviewHost(theme: .dark)
}

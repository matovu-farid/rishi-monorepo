import SwiftUI
import RishiUIKit
import RishiReader

/// App-wide reader defaults for new books. Per-book overrides remain inside
/// the reader; this section drives the value applied on FIRST open of each
/// new book.
///
/// `ReaderSettingsStore` is per-book (it takes a `BookID`), so the Settings
/// screen wires its own user-level defaults via the parent screen's
/// bindings — 11-06 backs them with UserDefaults keys
/// `reader.defaults.theme` / `reader.defaults.font` so the reader can read
/// them when opening a freshly imported book.
struct ReaderDefaultsSection: View {

    @Binding private var defaultTheme: ReaderTheme
    @Binding private var defaultFontFamily: ReaderFontFamily

    public init(
        defaultTheme: Binding<ReaderTheme>,
        defaultFontFamily: Binding<ReaderFontFamily>
    ) {
        self._defaultTheme = defaultTheme
        self._defaultFontFamily = defaultFontFamily
    }

    public var body: some View {
        Section {
            Picker("Theme", selection: $defaultTheme) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Text(label(for: theme)).tag(theme)
                }
            }
            .accessibilityIdentifier("settings-reader-theme")

            Picker("Font", selection: $defaultFontFamily) {
                ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                    Text(family.label).tag(family)
                }
            }
            .accessibilityIdentifier("settings-reader-font")
        } header: {
            Text("Reader Defaults")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        } footer: {
            Text("Applied to new books. You can override theme + font per book inside the reader.")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
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

private struct ReaderDefaultsSectionPreviewHost: View {
    @State private var theme: ReaderTheme = .light
    @State private var font: ReaderFontFamily = .system

    var body: some View {
        Form {
            ReaderDefaultsSection(
                defaultTheme: $theme,
                defaultFontFamily: $font
            )
        }
    }
}

#Preview("Light") {
    ReaderDefaultsSectionPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ReaderDefaultsSectionPreviewHost()
        .preferredColorScheme(.dark)
}

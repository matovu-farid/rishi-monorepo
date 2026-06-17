import Foundation
import RishiCore

/// In-memory fallback used by the theme + typography pickers when no
/// `ReaderSettingsStore` is injected (previews / tests). Writes are
/// no-ops; reads always return `.default`. Keeps the pickers' contract
/// trivially satisfiable without dragging UserDefaults into preview
/// environments. Shared by `PDFReaderScreen` and `EPUBReaderScreen`.
final class EphemeralReaderSettingsStore: ReaderSettingsStore, Sendable {
    func theme(for bookId: BookID) async -> ReaderTheme { .default }
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async { /* no-op */ }
    func typography(for bookId: BookID) async -> ReaderTypography { .default }
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { /* no-op */ }
}

import Foundation


/// Per-book reader settings (theme + typography).
///
/// Defined as a protocol so unit tests can stub in-memory and Phase 7
/// can introduce a GRDB-backed sync layer without touching either
/// reader view-model. Default impl is ``UserDefaultsReaderSettingsStore``.
///
/// Phase 5 shipped theme accessors; Phase 6 adds the typography
/// accessors (font family / font size / line height) needed by EPUB.
public protocol ReaderSettingsStore: Sendable {

    // MARK: - Theme (Phase 5)

    /// Returns the persisted theme for the book, or ``ReaderTheme/default``.
    func theme(for bookId: BookID) async -> ReaderTheme

    /// Returns the persisted theme when one exists, otherwise `nil`.
    func persistedTheme(for bookId: BookID) async -> ReaderTheme?

    /// Synchronous peek for first-frame hydration. Default `nil`.
    func peekPersistedTheme(for bookId: BookID) -> ReaderTheme?

    /// Persists `theme` for `bookId`. Overwrites any previous value.
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async

    // MARK: - Typography (Phase 6)

    /// Returns the persisted typography for the book, or ``ReaderTypography/default``.
    func typography(for bookId: BookID) async -> ReaderTypography

    /// Persists `typography` for `bookId`. Overwrites any previous value.
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async
}

public extension ReaderSettingsStore {
    func persistedTheme(for bookId: BookID) async -> ReaderTheme? {
        peekPersistedTheme(for: bookId)
    }

    func peekPersistedTheme(for bookId: BookID) -> ReaderTheme? { nil }

    /// Default impl returns `ReaderTypography.default`. Conformers that
    /// don't yet persist typography (e.g. tests) get the default
    /// without having to stub.
    func typography(for bookId: BookID) async -> ReaderTypography { .default }

    /// Default impl is a no-op for conformers that don't persist typography.
    func setTypography(_ typography: ReaderTypography, for bookId: BookID) async { }
}

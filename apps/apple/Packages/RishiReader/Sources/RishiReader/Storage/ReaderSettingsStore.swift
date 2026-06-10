import Foundation
import RishiCore

/// Per-book reader settings (theme today; brightness / font-size /
/// margins land in later Phase 5 + Phase 6 plans).
///
/// Defined as a protocol so unit tests can stub in-memory and Phase 7
/// can introduce a GRDB-backed sync layer without touching the
/// reader view-model. Default impl in Phase 5 is
/// ``UserDefaultsReaderSettingsStore``.
public protocol ReaderSettingsStore: Sendable {
    /// Returns the persisted theme for the book, or
    /// ``ReaderTheme/default`` when nothing has been stored yet.
    func theme(for bookId: BookID) async -> ReaderTheme

    /// Persists `theme` for `bookId`. Overwrites any previous value.
    func setTheme(_ theme: ReaderTheme, for bookId: BookID) async
}

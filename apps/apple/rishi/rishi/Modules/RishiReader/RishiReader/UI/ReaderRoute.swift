import Foundation


/// Push destination for the per-tab `NavigationStack(path:)` that hosts the reader.
/// Replaces the prior `.fullScreenCover(item:)` OpenTarget so the system back chevron
/// + edge-swipe-from-left are always available.
///
/// Codable so it can round-trip through `@SceneStorage` as a JSON-encoded String
/// (`@SceneStorage` only accepts a fixed set of primitive types; `Data` works but a
/// JSON String is easier to debug in `defaults read`).
public enum ReaderRoute: Hashable, Identifiable, Codable, Sendable {
    case pdf(BookID)
    case epub(BookID)
    case unsupportedFormat(BookID)

    public var id: BookID { bookId }

    public var bookId: BookID {
        switch self {
        case .pdf(let id), .epub(let id), .unsupportedFormat(let id): return id
        }
    }

    /// Mirrors the prior private `RootView.openTarget(for:)` switch so the call-site
    /// migration is a one-line swap.
    public static func route(for book: Book) -> ReaderRoute {
        switch book.formatType {
        case .pdf:         return .pdf(book.id)
        case .epub:        return .epub(book.id)
        case .mobi, .azw3: return .unsupportedFormat(book.id)
        }
    }
}

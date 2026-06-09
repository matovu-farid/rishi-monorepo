import Foundation
import RishiCore

/// A book that is currently in-progress (has a `Position` with
/// `0 < percentComplete < 1`). LIB-05 surfaces these in the Reading Now shelf.
public struct ReadingNowEntry: Identifiable, Sendable, Equatable {
    public let book: Book
    public let position: Position

    public var id: BookID { book.id }
    public var percentComplete: Double { position.percentComplete }

    public init(book: Book, position: Position) {
        self.book = book
        self.position = position
    }

    /// LIB-05 inclusion rule: a book is "in progress" iff its position is
    /// strictly between fresh (0) and finished (1).
    public static func isInProgress(_ position: Position) -> Bool {
        position.percentComplete > 0 && position.percentComplete < 1
    }
}

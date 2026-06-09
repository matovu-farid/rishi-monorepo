import Foundation
import RishiCore

extension Highlight {
    public static func fixture(
        id: HighlightID = UUID(),
        bookId: BookID = UUID(),
        locatorStart: String = "cfi-start",
        locatorEnd: String = "cfi-end",
        color: HighlightColor = .yellow,
        text: String = "Fixture highlight text.",
        note: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Highlight {
        Highlight(
            id: id,
            bookId: bookId,
            locatorStart: locatorStart,
            locatorEnd: locatorEnd,
            color: color,
            text: text,
            note: note,
            createdAt: createdAt
        )
    }
}

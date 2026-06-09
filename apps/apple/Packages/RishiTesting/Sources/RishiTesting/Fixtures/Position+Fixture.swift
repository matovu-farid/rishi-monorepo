import Foundation
import RishiCore

extension Position {
    public static func fixture(
        id: PositionID = UUID(),
        bookId: BookID = UUID(),
        locator: String = "epubcfi(/6/4!/4/10/2,1:0,1:8)",
        percentComplete: Double = 0.1,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Position {
        Position(
            id: id,
            bookId: bookId,
            locator: locator,
            percentComplete: percentComplete,
            updatedAt: updatedAt
        )
    }
}

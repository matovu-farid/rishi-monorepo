import Foundation


extension Bookmark {
    public static func fixture(
        id: BookmarkID = UUID(),
        bookId: BookID = UUID(),
        locator: String = "{\"format\":\"pdf-bmk-v1\",\"page\":0}",
        label: String? = nil,
        snippet: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Bookmark {
        Bookmark(
            id: id,
            bookId: bookId,
            locator: locator,
            label: label,
            snippet: snippet,
            createdAt: createdAt
        )
    }
}

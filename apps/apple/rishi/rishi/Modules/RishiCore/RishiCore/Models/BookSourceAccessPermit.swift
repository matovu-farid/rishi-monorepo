import Foundation

/// Identifies one immutable source instance. Replacing a source always creates
/// a new permit, even when the BookID and content digest are unchanged.
public struct BookSourceAccessPermit: Sendable, Hashable {
    public let sourceInstanceID: UUID

    public init(sourceInstanceID: UUID = UUID()) {
        self.sourceInstanceID = sourceInstanceID
    }
}

public enum BookSourceAccess: Sendable, Equatable {
    case account(BookReadingPermit)
    case localPreview
}

public enum BookSourceAccessError: Error, Sendable, Equatable {
    case revoked
    case unknownSource
}

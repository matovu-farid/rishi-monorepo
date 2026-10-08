import Foundation

public enum PositionCommitResult: Sendable, Equatable {
    case committed
    case publicationDeferred
}

/// Captured authority for publishing an already durable reader position. The
/// finite admission retains services and immutable permits, never a reader or source owner.
public struct ReaderPositionPublicationAuthority: Sendable {
    public let permit: BookReadingPermit
    public let source: BookSourceAccessPermit
    private let admission: @Sendable () async throws -> SourceEffectAdmission

    public init(permit: BookReadingPermit, source: BookSourceAccessPermit,
                admitMetadata: @escaping @Sendable () async throws -> SourceEffectAdmission) {
        self.permit = permit
        self.source = source
        self.admission = admitMetadata
    }

    public func admitMetadata() async throws -> SourceEffectAdmission {
        try await admission()
    }
}

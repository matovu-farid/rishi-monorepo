import Foundation

public enum SyncIntegrityClassification: String, Sendable, Equatable {
    case hashMatch
    case hashMismatch
    case deferredPendingLocalChanges
    case incompleteProjection
    case legacyWorker
    case verificationUnavailable
}

public struct SyncIntegrityObservation: Sendable, Equatable {
    public let classification: SyncIntegrityClassification
    public let scope: SyncCursorScope
    public let diffPaths: [String]
    public let redactedDescription: String

    public init(
        classification: SyncIntegrityClassification,
        scope: SyncCursorScope,
        diffPaths: [String] = [],
        redactedDescription: String = ""
    ) {
        self.classification = classification
        self.scope = scope
        self.diffPaths = diffPaths
        self.redactedDescription = redactedDescription
    }
}

/// Compares the server projection with itself, then reports local semantic
/// differences separately. Local pending data is never merged into the hash
/// input, so a pending edit cannot manufacture a false server mismatch.
public struct SyncIntegrityVerifier: Sendable {
    public init() {}

    public func observe(
        remote: SyncObject,
        local: SyncObject?,
        pendingLocalCount: Int,
        scope: SyncCursorScope,
        hashVersion: String?,
        projectionComplete: Bool
    ) throws -> SyncIntegrityObservation {
        guard projectionComplete, !remote.isTruncated else {
            return SyncIntegrityObservation(
                classification: .incompleteProjection,
                scope: scope,
                redactedDescription: "projection incomplete"
            )
        }
        guard let hashVersion else {
            return SyncIntegrityObservation(
                classification: .legacyWorker,
                scope: scope,
                redactedDescription: "worker hash unavailable"
            )
        }
        guard hashVersion == "sync-json-v1", let remoteHash = remote.remoteHash else {
            return SyncIntegrityObservation(
                classification: .verificationUnavailable,
                scope: scope,
                redactedDescription: "unsupported or unavailable hash version"
            )
        }

        let observedHash = try remote.canonicalHash()
        let hashClassification: SyncIntegrityClassification = observedHash == remoteHash ? .hashMatch : .hashMismatch
        let diffPaths = local.map { remote.diff(against: $0) } ?? []
        let classification = pendingLocalCount > 0 ? .deferredPendingLocalChanges : hashClassification
        return SyncIntegrityObservation(
            classification: classification,
            scope: scope,
            diffPaths: diffPaths,
            redactedDescription: "\(classification.rawValue); diff_count=\(diffPaths.count)"
        )
    }
}

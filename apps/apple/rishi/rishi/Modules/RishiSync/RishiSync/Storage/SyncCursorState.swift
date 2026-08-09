import Foundation
import SwiftData

/// Durable progress for one sync plane. The cursor is opaque to Apple; only
/// the Worker owns its encoding and tuple semantics.
public struct SyncCursorState: Codable, Sendable, Equatable, Hashable {
    public let scope: SyncCursorScope
    public let cursor: String
    public let accountGeneration: Int

    public init(scope: SyncCursorScope, cursor: String, accountGeneration: Int = 0) {
        self.scope = scope
        self.cursor = cursor
        self.accountGeneration = accountGeneration
    }
}

public enum SyncRecoveryReason: String, Codable, Sendable, Equatable, Hashable {
    case incompleteProjection
}

public struct SyncRecoveryState: Codable, Sendable, Equatable, Hashable {
    public let reason: SyncRecoveryReason
    public let accountGeneration: Int

    public init(reason: SyncRecoveryReason, accountGeneration: Int = 0) {
        self.reason = reason
        self.accountGeneration = accountGeneration
    }
}

/// SwiftData storage row for cursor progress. It deliberately has no entity
/// identifier or dirty bit, so progress cannot be inferred from or cleared by
/// entity-level acknowledgement code.
@Model
final class SyncCursorStateRow {
    @Attribute(.unique) var scope: String
    var cursor: String
    var accountGeneration: Int = 0

    init(scope: String, cursor: String, accountGeneration: Int = 0) {
        self.scope = scope
        self.cursor = cursor
        self.accountGeneration = accountGeneration
    }
}

@Model
final class SyncRecoveryStateRow {
    @Attribute(.unique) var id: String
    var reason: String
    var accountGeneration: Int = 0

    init(id: String = "account", reason: String, accountGeneration: Int = 0) {
        self.id = id
        self.reason = reason
        self.accountGeneration = accountGeneration
    }
}

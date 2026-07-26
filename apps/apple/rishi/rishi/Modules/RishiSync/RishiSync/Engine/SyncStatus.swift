import Foundation
import Observation

/// Observable surface for the Settings sync row (SYNC-07).
///
/// `@Observable` final class so SwiftUI views in 07-05 can bind to
/// individual fields. `@unchecked Sendable` because all mutations route
/// through `SyncEngine` actor calls and we use the box only as the
/// SwiftUI read side — mirrors `LibraryViewModel` from Phase 4 and
/// `PDFReaderViewModel` from Phase 5.
@Observable
public final class SyncStatus: @unchecked Sendable {

    public var lastSyncedAt: Date?
    public var pendingCount: Int
    public var isRunning: Bool
    public var lastError: String?

    public init(
        lastSyncedAt: Date? = nil,
        pendingCount: Int = 0,
        isRunning: Bool = false,
        lastError: String? = nil
    ) {
        self.lastSyncedAt = lastSyncedAt
        self.pendingCount = pendingCount
        self.isRunning = isRunning
        self.lastError = lastError
    }

    /// Frozen, Sendable snapshot for cross-actor reads/tests.
    public func snapshot() -> SyncStatusSnapshot {
        SyncStatusSnapshot(
            lastSyncedAt: lastSyncedAt,
            pendingCount: pendingCount,
            isRunning: isRunning,
            lastError: lastError
        )
    }

    /// Atomic update — call from `SyncEngine` after a sync run.
    public func apply(_ snapshot: SyncStatusSnapshot) {
        self.lastSyncedAt = snapshot.lastSyncedAt
        self.pendingCount = snapshot.pendingCount
        self.isRunning = snapshot.isRunning
        self.lastError = snapshot.lastError
    }
}

/// Frozen value type — Sendable for cross-actor transport.
public struct SyncStatusSnapshot: Sendable, Equatable {
    public let lastSyncedAt: Date?
    public let pendingCount: Int
    public let isRunning: Bool
    public let lastError: String?

    public init(lastSyncedAt: Date?, pendingCount: Int, isRunning: Bool, lastError: String?) {
        self.lastSyncedAt = lastSyncedAt
        self.pendingCount = pendingCount
        self.isRunning = isRunning
        self.lastError = lastError
    }
}

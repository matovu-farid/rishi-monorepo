import Foundation

/// Durable Watch-side acceptance state. A verified snapshot can establish a
/// new phone process only after the Watch has begun a fresh handshake; cached
/// contexts from an older process are never treated as authorization.
public struct WatchSnapshotAcceptance: Sendable, Equatable {
    public private(set) var minimumRedactionRevision: UInt64
    public private(set) var minimumAccountGeneration: UInt64
    public private(set) var trustedProcessSessionID: UUID?
    public private(set) var hasFreshHandshake: Bool

    public init(
        minimumRedactionRevision: UInt64 = 0,
        minimumAccountGeneration: UInt64 = 0,
        trustedProcessSessionID: UUID? = nil,
        hasFreshHandshake: Bool = false
    ) {
        self.minimumRedactionRevision = minimumRedactionRevision
        self.minimumAccountGeneration = minimumAccountGeneration
        self.trustedProcessSessionID = trustedProcessSessionID
        self.hasFreshHandshake = hasFreshHandshake
    }

    public mutating func beginHandshake() {
        hasFreshHandshake = false
    }

    public mutating func accept(
        _ snapshot: WatchPlaybackSnapshot,
        expectedHandshakeNonce: UUID,
        expectedActivationSequence: UInt64
    ) -> Bool {
        guard snapshot.handshakeNonce == expectedHandshakeNonce,
              snapshot.activationSequence == expectedActivationSequence else { return false }
        guard snapshot.redactionTrust == .verified else {
            if snapshot.redactionRevision > minimumRedactionRevision {
                minimumRedactionRevision = snapshot.redactionRevision
            }
            trustedProcessSessionID = nil
            hasFreshHandshake = false
            return true
        }
        guard snapshot.redactionRevision >= minimumRedactionRevision,
              snapshot.accountGeneration >= minimumAccountGeneration else { return false }
        if hasFreshHandshake,
           let trustedProcessSessionID,
           trustedProcessSessionID != snapshot.processSessionID {
            return false
        }
        trustedProcessSessionID = snapshot.processSessionID
        minimumRedactionRevision = max(minimumRedactionRevision, snapshot.redactionRevision)
        minimumAccountGeneration = max(minimumAccountGeneration, snapshot.accountGeneration)
        hasFreshHandshake = true
        return true
    }
}

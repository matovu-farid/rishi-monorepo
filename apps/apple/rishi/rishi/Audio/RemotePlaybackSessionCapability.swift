import Foundation

/// Capability for one active narration session. Individual command leases are
/// children of this capability and cannot outlive it.
final class RemotePlaybackSessionCapability: @unchecked Sendable {
    let processSessionID: UUID
    let accountGeneration: UInt64
    let playbackGeneration: UInt64

    private let lock = NSLock()
    private var active = true

    init(processSessionID: UUID, accountGeneration: UInt64, playbackGeneration: UInt64) {
        self.processSessionID = processSessionID
        self.accountGeneration = accountGeneration
        self.playbackGeneration = playbackGeneration
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func issueCommandLease() -> RemoteCommandLease? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return RemoteCommandLease(
            processSessionID: processSessionID,
            accountGeneration: accountGeneration,
            playbackGeneration: playbackGeneration
        )
    }

    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

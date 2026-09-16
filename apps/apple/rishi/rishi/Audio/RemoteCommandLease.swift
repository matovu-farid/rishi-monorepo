import Foundation

/// One admitted remote mutation. The lock makes revocation safe when an
/// account transition races an async playback operation.
final class RemoteCommandLease: @unchecked Sendable, TTSMutationLease {
    let processSessionID: UUID
    let accountGeneration: UInt64
    let playbackGeneration: UInt64

    private let lock = NSLock()
    private var active = true
    private var finished = false

    init(processSessionID: UUID, accountGeneration: UInt64, playbackGeneration: UInt64) {
        self.processSessionID = processSessionID
        self.accountGeneration = accountGeneration
        self.playbackGeneration = playbackGeneration
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && !finished
    }

    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        active = false
        return true
    }
}

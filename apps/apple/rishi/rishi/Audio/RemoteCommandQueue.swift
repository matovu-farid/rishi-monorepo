import Foundation
import RishiWatchShared

/// MainActor admission boundary for Watch commands. The transport ledger
/// handles duplicate request IDs; this queue handles the live process,
/// account, playback, and handshake epochs.
@MainActor
final class RemoteCommandQueue {
    private let processSessionID: UUID
    private var accountGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var clientID: UUID?
    private var handshake: (UUID, UInt64)?
    private var session: RemotePlaybackSessionCapability?

    init(processSessionID: UUID = UUID()) {
        self.processSessionID = processSessionID
    }

    func installAccountGeneration(_ generation: UInt64) {
        revokeAll()
        accountGeneration = generation
        clientID = nil
        handshake = nil
    }

    func installPlaybackSession(accountGeneration: UInt64, playbackGeneration: UInt64) {
        if let session,
           session.isValid,
           self.accountGeneration == accountGeneration,
           self.playbackGeneration == playbackGeneration {
            return
        }
        session?.revoke()
        self.accountGeneration = accountGeneration
        self.playbackGeneration = playbackGeneration
        session = RemotePlaybackSessionCapability(
            processSessionID: processSessionID,
            accountGeneration: accountGeneration,
            playbackGeneration: playbackGeneration
        )
    }

    func revokePlaybackSession() {
        session?.revoke()
        session = nil
    }

    func installHandshake(clientID: UUID, nonce: UUID, activationSequence: UInt64) -> Bool {
        if let current = handshake {
            if activationSequence < current.1 { return false }
            if activationSequence == current.1,
               nonce != current.0 || clientID != self.clientID {
                return false
            }
        }
        self.clientID = clientID
        handshake = (nonce, activationSequence)
        return true
    }

    func admit(_ envelope: WatchMutatingCommandEnvelope) -> RemoteCommandLease? {
        guard envelope.processSessionID == processSessionID,
              envelope.accountGeneration == accountGeneration,
              envelope.playbackGeneration == playbackGeneration,
              envelope.watchClientID == clientID,
              handshake?.0 == envelope.handshakeNonce,
              handshake?.1 == envelope.activationSequence,
              let session,
              session.isValid else { return nil }
        return session.issueCommandLease()
    }

    func revokeAll() {
        session?.revoke()
        session = nil
        handshake = nil
        clientID = nil
    }
}

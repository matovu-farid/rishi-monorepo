import Foundation
import RishiWatchShared
import Testing
@testable import rishi

@Suite("Remote command admission")
@MainActor
struct RemoteCommandQueueTests {
    @Test("a revoked command lease cannot be reused")
    func leaseRevocation() {
        let lease = RemoteCommandLease(
            processSessionID: UUID(), accountGeneration: 2, playbackGeneration: 7
        )
        #expect(lease.isValid)
        lease.revoke()
        #expect(!lease.isValid)
        #expect(!lease.finish())
    }

    @Test("admission requires the current process, account, playback, and handshake")
    func epochAdmission() {
        let process = UUID()
        let client = UUID()
        let nonce = UUID()
        let queue = RemoteCommandQueue(processSessionID: process)
        queue.installAccountGeneration(2)
        queue.installPlaybackSession(accountGeneration: 2, playbackGeneration: 7)
        #expect(queue.installHandshake(clientID: client, nonce: nonce, activationSequence: 4))

        let envelope = WatchMutatingCommandEnvelope(
            processSessionID: process,
            watchClientID: client,
            handshakeNonce: nonce,
            activationSequence: 4,
            clientSequence: 1,
            requestID: UUID(),
            playbackGeneration: 7,
            accountGeneration: 2,
            command: .togglePlayback
        )
        let lease = queue.admit(envelope)
        #expect(lease?.isValid == true)

        let stale = WatchMutatingCommandEnvelope(
            processSessionID: process,
            watchClientID: client,
            handshakeNonce: UUID(),
            activationSequence: 4,
            clientSequence: 2,
            requestID: UUID(),
            playbackGeneration: 7,
            accountGeneration: 2,
            command: .togglePlayback
        )
        #expect(queue.admit(stale) == nil)
        queue.revokeAll()
        #expect(!lease!.isValid)
    }

    @Test("an equal activation sequence cannot rotate the handshake nonce")
    func equalSequenceCannotRotateNonce() {
        let queue = RemoteCommandQueue(processSessionID: UUID())
        let client = UUID()
        let original = UUID()
        #expect(queue.installHandshake(clientID: client, nonce: original, activationSequence: 4))
        #expect(!queue.installHandshake(clientID: client, nonce: UUID(), activationSequence: 4))
        #expect(queue.installHandshake(clientID: client, nonce: original, activationSequence: 4))
    }
}

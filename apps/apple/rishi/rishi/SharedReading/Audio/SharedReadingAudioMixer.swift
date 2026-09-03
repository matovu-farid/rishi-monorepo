import Foundation
@preconcurrency import LiveKitWebRTC

struct SharedReadingAudioMixerSnapshot: Sendable, Equatable {
    let connectedPeerUserIds: Set<String>
    let remoteAudioUserIds: Set<String>
}

/// Keeps shared-reading media state together without taking ownership of the
/// app-wide TTS engine. LiveKit owns WebRTC playout; retaining each received
/// track here lets the session consume that playout independently.
@MainActor
final class SharedReadingAudioMixer {
    private var peerStates: [String: SharedReadingPeerConnectionState] = [:]
    private var remoteAudioTracks: [String: SharedReadingRemoteAudioTrack] = [:]

    func consume(peerState event: SharedReadingPeerStateEvent) {
        peerStates[event.userId] = event.state
        if event.state == .failed || event.state == .closed || event.state == .disconnected {
            remoteAudioTracks.removeValue(forKey: event.userId)
        }
    }

    func consume(remoteAudio event: SharedReadingRemoteAudioTrack) {
        remoteAudioTracks[event.userId] = event
        event.track.isEnabled = true
    }

    func snapshot() -> SharedReadingAudioMixerSnapshot {
        SharedReadingAudioMixerSnapshot(
            connectedPeerUserIds: Set(peerStates.compactMap { userId, state in
                state == .connected ? userId : nil
            }),
            remoteAudioUserIds: Set(remoteAudioTracks.keys)
        )
    }
}

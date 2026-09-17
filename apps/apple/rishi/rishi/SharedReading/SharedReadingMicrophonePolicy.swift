import Foundation

/// The user's mute choice is persistent across the two room audio gates.
/// During active TTS, the moderated floor additionally requires a deliberate
/// hold-to-talk gesture and a server-granted speaker floor.
struct SharedReadingMicrophonePolicyState: Sendable, Equatable {
    var userMuted = false
    var holdToTalk = false
    var speakerFloorGranted = false

    func microphoneEnabled(isTTSPlaying: Bool) -> Bool {
        guard !userMuted else { return false }
        guard isTTSPlaying else { return true }
        return holdToTalk && speakerFloorGranted
    }
}

enum SharedReadingMicrophonePolicy {
    static func setMuted(_ muted: Bool, in state: SharedReadingMicrophonePolicyState) -> SharedReadingMicrophonePolicyState {
        var next = state
        next.userMuted = muted
        return next
    }

    static func setHoldToTalk(_ holding: Bool, in state: SharedReadingMicrophonePolicyState) -> SharedReadingMicrophonePolicyState {
        var next = state
        next.holdToTalk = holding
        return next
    }

    static func setSpeakerFloorGranted(_ granted: Bool, in state: SharedReadingMicrophonePolicyState) -> SharedReadingMicrophonePolicyState {
        var next = state
        next.speakerFloorGranted = granted
        return next
    }
}

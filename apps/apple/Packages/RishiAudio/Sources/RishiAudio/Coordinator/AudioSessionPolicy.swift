import Foundation

/// Pure reducer that decides what the shared AVAudioSession must do in response
/// to a TTS / Voice / interruption event. Extracted from `AudioSessionCoordinator`
/// so every session decision is unit-testable without an actor, async, or AVFAudio.
///
/// The key invariant this exists to protect: a passage switch (next/prev/repeat
/// while already playing TTS) must NOT churn the session — no deactivate, no
/// reconfigure. Churn loses the active audio route and was the cause of a
/// device-only "silent next/prev paragraph" bug.
///
/// Mirrors the pure-reducer style of `PlaybackCompletionAccountant`.
public enum AudioSessionEvent: Sendable, Equatable {
    case beginPassage   // start a fresh TTS passage
    case switchPassage  // next/prev/repeat while already playing
    case endPlayback    // stop TTS
    case beginVoice
    case endVoice
    case interrupted
    case resume
    case endInterruptionNoResume
}

public enum AudioSessionEffect: Sendable, Equatable {
    case configure(category: AudioSessionCategory, mode: AudioSessionMode, options: AudioSessionOptions)
    case activate
    case deactivate(notifyOthers: Bool)
}

public struct AudioSessionPolicy: Sendable {
    public private(set) var mode: ActiveMode = .idle
    public private(set) var isSuspended: Bool = false

    public init() {}

    private static let ttsConfigure: AudioSessionEffect = .configure(
        category: .playback,
        mode: .spokenAudio,
        options: [.allowBluetooth, .allowAirPlay]
    )

    private static let voiceConfigure: AudioSessionEffect = .configure(
        category: .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetooth]
    )

    public mutating func reduce(_ event: AudioSessionEvent) -> [AudioSessionEffect] {
        switch event {
        case .beginPassage, .switchPassage:
            return startTTS()

        case .endPlayback:
            guard mode == .tts else { return [] }
            mode = .idle
            isSuspended = false
            return [.deactivate(notifyOthers: true)]

        case .beginVoice:
            return startVoice()

        case .endVoice:
            guard mode == .voice else { return [] }
            mode = .idle
            isSuspended = false
            return [.deactivate(notifyOthers: true)]

        case .interrupted:
            isSuspended = true
            return []

        case .resume:
            guard mode != .idle else { return [] }
            isSuspended = false
            return [.activate]

        case .endInterruptionNoResume:
            mode = .idle
            isSuspended = false
            return []
        }
    }

    private mutating func startTTS() -> [AudioSessionEffect] {
        // Already actively playing TTS: a switch must not churn the session.
        if mode == .tts, !isSuspended { return [] }

        var effects: [AudioSessionEffect] = []
        // A different owner (voice) must be torn down first.
        if mode == .voice {
            effects.append(.deactivate(notifyOthers: true))
        }
        effects.append(Self.ttsConfigure)
        effects.append(.activate)
        mode = .tts
        isSuspended = false
        return effects
    }

    private mutating func startVoice() -> [AudioSessionEffect] {
        if mode == .voice, !isSuspended { return [] }

        var effects: [AudioSessionEffect] = []
        if mode == .tts {
            effects.append(.deactivate(notifyOthers: true))
        }
        effects.append(Self.voiceConfigure)
        effects.append(.activate)
        mode = .voice
        isSuspended = false
        return effects
    }
}

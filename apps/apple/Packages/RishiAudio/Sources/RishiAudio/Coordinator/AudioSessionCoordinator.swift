import Foundation
import RishiLogging

/// Shared actor that owns the singleton AVAudioSession configuration on
/// behalf of TTS (Phase 8) and Voice Chat (Phase 10). Only ONE active mode
/// at a time — requesting `.voice` while `.tts` is active tears down TTS's
/// configuration first.
///
/// All session DECISIONS live in the pure `AudioSessionPolicy` reducer; this
/// actor is a thin shell that maps the public API onto policy events and
/// applies the reducer's effects against the injected configurator.
///
/// Pitfall 8 + Pitfall (voice/spokenAudio mode): centralise here so subsystem
/// code never touches AVAudioSession directly.
public actor AudioSessionCoordinator {

    private let configurator: any AudioSessionConfigurator
    private var policy = AudioSessionPolicy()
    private var interruptionTask: Task<Void, Never>?

    public init(configurator: any AudioSessionConfigurator) {
        self.configurator = configurator
        // KEEP: fire-and-forget actor hop from `init`; startInterruptionLoop is
        // an actor-isolated method that subscribes to the interruption stream.
        // Outer Task only chains the actor await; no main-bound work.
        Task { await self.startInterruptionLoop() }
    }

    deinit {
        interruptionTask?.cancel()
    }

    public var currentMode: ActiveMode { policy.mode }
    public var isSuspended: Bool { policy.isSuspended }

    /// Apply the reducer's effects against the underlying configurator.
    private func apply(_ effects: [AudioSessionEffect]) {
        for effect in effects {
            switch effect {
            case let .configure(category, mode, options):
                do {
                    try configurator.configure(category: category, mode: mode, options: options)
                } catch {
                    Log.event("audio.session.mode.failed", level: .error, data: [
                        "error": String(describing: error),
                    ])
                }
            case .activate:
                try? configurator.setActive(true, notifyOthers: false)
            case let .deactivate(notifyOthers):
                try? configurator.setActive(false, notifyOthers: notifyOthers)
            }
        }
    }

    /// Request the coordinator switch (or stay in) the given mode. Returns
    /// after the underlying configurator has finished its work.
    public func requestActiveMode(_ mode: ActiveMode) async {
        switch mode {
        case .idle:
            return
        case .tts:
            // Already in .tts means this is a passage switch (next/prev/repeat),
            // which the policy treats as a no-churn no-op when not suspended.
            apply(policy.reduce(policy.mode == .tts ? .switchPassage : .beginPassage))
            Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
        case .voice:
            apply(policy.reduce(.beginVoice))
            Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
        }
    }

    /// Release a mode. Only the current owner can release — calling
    /// `releaseActiveMode(.tts)` while the coordinator is in `.voice` is a
    /// no-op (prevents TTS from accidentally evicting voice chat).
    public func releaseActiveMode(_ mode: ActiveMode) async {
        switch mode {
        case .idle:
            return
        case .tts:
            apply(policy.reduce(.endPlayback))
        case .voice:
            apply(policy.reduce(.endVoice))
        }
        Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
    }

    // MARK: - Interruption handling

    private func startInterruptionLoop() async {
        let stream = configurator.interruptionStream()
        // KEEP: AsyncStream consumer task started from inside the actor; runs
        // on the actor's executor (not main) and forwards each event back to
        // the actor's handleInterruption.
        interruptionTask = Task { [weak self] in
            for await event in stream {
                await self?.handleInterruption(event)
            }
        }
    }

    private func handleInterruption(_ event: AudioInterruptionEvent) async {
        switch event {
        case .began:
            apply(policy.reduce(.interrupted))
            Log.event("audio.interruption", level: .info, data: ["event": "began"])
        case .endedShouldResume:
            apply(policy.reduce(.resume))
            Log.event("audio.interruption", level: .info, data: ["event": "ended.shouldResume"])
        case .endedNoResume:
            apply(policy.reduce(.endInterruptionNoResume))
            Log.event("audio.interruption", level: .info, data: ["event": "ended.noResume"])
        }
    }
}

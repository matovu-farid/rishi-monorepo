import Foundation


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
    private var routeChangeTask: Task<Void, Never>?

    /// Per-mode "stop the owner" closures. The coordinator invokes the
    /// OUTGOING mode's closure before granting a different mode, so the
    /// displaced owner (TTS engine / voice session) is fully torn down — not
    /// just its AVAudioSession config. Enforces the single-audio-owner
    /// invariant at the resource owner. `@Sendable` to cross actor boundaries.
    private var preemptHandlers: [ActiveMode: @Sendable () async -> Void] = [:]
    private var suspensionHandlers: [ActiveMode: @Sendable () async -> Void] = [:]

    /// Register the closure that fully stops the owner of `mode`. Owners call
    /// this just before they `requestActiveMode(mode)`. Re-registering
    /// overwrites (e.g. a fresh per-session voice owner).
    public func registerPreemption(for mode: ActiveMode, handler: @escaping @Sendable () async -> Void) {
        preemptHandlers[mode] = handler
    }

    /// Register the active owner's pause action for system interruptions and
    /// output-route loss. Suspension deliberately keeps ownership in policy so
    /// an explicit Play action can resume the same TTS session.
    public func registerSuspension(for mode: ActiveMode, handler: @escaping @Sendable () async -> Void) {
        suspensionHandlers[mode] = handler
    }

    /// Await the outgoing owner's stop closure (if any). The closure typically
    /// calls back into `releaseActiveMode`, which the actor processes while
    /// this call is suspended — leaving the policy at `.idle` before the new
    /// mode is applied.
    private func preempt(_ mode: ActiveMode) async {
        guard let handler = preemptHandlers[mode] else { return }
        await handler()
    }

    private func suspend(_ mode: ActiveMode) async {
        guard let handler = suspensionHandlers[mode] else { return }
        await handler()
    }

    public init(configurator: any AudioSessionConfigurator) {
        self.configurator = configurator
        // KEEP: fire-and-forget actor hop from `init`; startInterruptionLoop is
        // an actor-isolated method that subscribes to the interruption stream.
        // Outer Task only chains the actor await; no main-bound work.
        Task { await self.startInterruptionLoop() }
        Task { await self.startRouteChangeLoop() }
    }

    deinit {
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
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
            // Owner change: a live voice session must be stopped first.
            if policy.mode == .voice { await preempt(.voice) }
            // Already in .tts means this is a passage switch (next/prev/repeat),
            // which the policy treats as a no-churn no-op when not suspended.
            apply(policy.reduce(policy.mode == .tts ? .switchPassage : .beginPassage))
            Log.event("audio.session.mode", level: .info, data: ["mode": policy.mode.rawValue])
        case .voice:
            // Owner change: live read-aloud must be stopped first.
            if policy.mode == .tts { await preempt(.tts) }
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

    private func startRouteChangeLoop() async {
        let stream = configurator.routeChangeStream()
        routeChangeTask = Task { [weak self] in
            for await event in stream {
                await self?.handleRouteChange(event)
            }
        }
    }

    private func handleInterruption(_ event: AudioInterruptionEvent) async {
        switch event {
        case .began:
            if policy.mode == .tts { await suspend(.tts) }
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

    private func handleRouteChange(_ event: AudioRouteChangeEvent) async {
        switch event {
        case .oldDeviceUnavailable:
            if policy.mode == .tts { await suspend(.tts) }
            apply(policy.reduce(.routeUnavailable))
            Log.event("audio.route.changed", level: .info, data: ["event": "oldDeviceUnavailable"])
        case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep, .noSuitableRoute, .unknown:
            // A route becoming available must not implicitly resume narration.
            // The active reader can explicitly request `.tts` to resume.
            Log.event("audio.route.changed", level: .debug, data: ["event": String(describing: event)])
        }
    }
}

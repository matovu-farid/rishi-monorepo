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
    private var recoveryHandlers: [ActiveMode: @Sendable () async -> Void] = [:]
    private var suspensionHandlers: [ActiveMode: @Sendable () async -> Void] = [:]
    private var handlerOwners: [ActiveMode: UUID] = [:]

    /// Register the closure that fully stops the owner of `mode`. Owners call
    /// this just before they `requestActiveMode(mode)`. Re-registering
    /// overwrites (e.g. a fresh per-session voice owner).
    public func registerPreemption(for mode: ActiveMode, ownerID: UUID? = nil, handler: @escaping @Sendable () async -> Void) {
        preemptHandlers[mode] = handler
        if let ownerID { handlerOwners[mode] = ownerID }
    }

    public func registerRecovery(for mode: ActiveMode, ownerID: UUID? = nil, handler: @escaping @Sendable () async -> Void) {
        recoveryHandlers[mode] = handler
        if let ownerID { handlerOwners[mode] = ownerID }
    }

    public func unregisterHandlers(for mode: ActiveMode, ownerID: UUID? = nil) {
        if let ownerID, handlerOwners[mode] != ownerID { return }
        preemptHandlers[mode] = nil
        recoveryHandlers[mode] = nil
        suspensionHandlers[mode] = nil
        handlerOwners[mode] = nil
    }

    /// Register the active owner's pause action for system interruptions and
    /// output-route loss. Suspension deliberately keeps ownership in policy so
    /// an explicit Play action can resume the same TTS session.
    public func registerSuspension(for mode: ActiveMode, ownerID: UUID? = nil, handler: @escaping @Sendable () async -> Void) {
        suspensionHandlers[mode] = handler
        if let ownerID { handlerOwners[mode] = ownerID }
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
    private func apply(_ effects: [AudioSessionEffect]) -> Bool {
        for effect in effects {
            switch effect {
            case let .configure(category, mode, options):
                do {
                    try configurator.configure(category: category, mode: mode, options: options)
                } catch {
                    Log.error(
                        "audio.session.mode.failed",
                        error: error,
                        diagnostic: TelemetryDiagnostic(
                            feature: "tts",
                            operation: "audio.session",
                            stage: "configure",
                            errorCode: "audio_session_configure_failed"
                        )
                    )
                    return false
                }
            case .activate:
                do {
                    try configurator.setActive(true, notifyOthers: false)
                } catch {
                    Log.error(
                        "audio.session.activation.failed",
                        error: error,
                        diagnostic: TelemetryDiagnostic(
                            feature: "tts",
                            operation: "audio.session",
                            stage: "activate",
                            errorCode: "audio_session_activation_failed"
                        )
                    )
                    // A configure effect may already have changed the
                    // underlying session before activation failed. Best-effort
                    // deactivation prevents a partially acquired route from
                    // surviving while policy rolls back.
                    try? configurator.setActive(false, notifyOthers: true)
                    return false
                }
            case let .deactivate(notifyOthers):
                do {
                    try configurator.setActive(false, notifyOthers: notifyOthers)
                } catch {
                    Log.error(
                        "audio.session.deactivation.failed",
                        error: error,
                        diagnostic: TelemetryDiagnostic(
                            feature: "tts",
                            operation: "audio.session",
                            stage: "deactivate",
                            errorCode: "audio_session_deactivation_failed"
                        )
                    )
                    return false
                }
            }
        }
        return true
    }

    /// Request the coordinator switch (or stay in) the given mode. Returns
    /// after the underlying configurator has finished its work.
    @discardableResult
    public func requestActiveMode(_ mode: ActiveMode) async -> Bool {
        switch mode {
        case .idle:
            return true
        case .tts:
            // Owner change: a live voice session must be stopped first.
            if policy.mode == .voice { await preempt(.voice) }
            // Already in .tts means this is a passage switch (next/prev/repeat),
            // which the policy treats as a no-churn no-op when not suspended.
            var nextPolicy = policy
            let applied = apply(nextPolicy.reduce(policy.mode == .tts ? .switchPassage : .beginPassage))
            // TTS historically treated AVAudioSession setup as best effort:
            // Readium / AVAudioEngine may be able to reuse an already-valid
            // route even when one of the redundant category operations throws.
            // Keep that compatibility contract. Voice remains fail-fast via
            // requestVoiceActiveMode(), where continuing would create a
            // connected-but-unusable duplex session.
            policy = nextPolicy
            Log.event("audio.session.mode", level: applied ? .info : .warning, data: [
                "mode": policy.mode.rawValue,
                "success": String(applied),
            ])
            return true
        case .voice:
            return await requestVoiceActiveMode()
        }
    }

    /// Voice-only acquisition API. Unlike the legacy `requestActiveMode` API,
    /// this reports whether AVAudioSession was actually configured and
    /// activated, allowing voice startup to fail before any network work.
    @discardableResult
    public func requestVoiceActiveMode() async -> Bool {
        // Owner change: live read-aloud must be stopped first.
        let displacedMode = policy.mode
        let displacedWasSuspended = policy.isSuspended
        if displacedMode == .tts { await preempt(.tts) }

        var nextPolicy = policy
        let applied = apply(nextPolicy.reduce(.beginVoice))
        if applied {
            policy = nextPolicy
        } else if displacedMode == .tts {
            // Voice acquisition failed after TTS was paused. Restore the
            // shared playback route and let the owner resume itself; never
            // report a stale .tts policy without restoring its audio path.
            var restoredPolicy = AudioSessionPolicy()
            if apply(restoredPolicy.reduce(.beginPassage)) {
                if displacedWasSuspended {
                    _ = restoredPolicy.reduce(.interrupted)
                    do {
                        try configurator.setActive(false, notifyOthers: true)
                    } catch {
                        Log.error(
                            "audio.session.recovery.deactivation.failed",
                            error: error,
                            diagnostic: TelemetryDiagnostic(
                                feature: "tts",
                                operation: "audio.session",
                                stage: "recover",
                                errorCode: "audio_session_recovery_failed"
                            )
                        )
                        policy = AudioSessionPolicy()
                        return false
                    }
                }
                policy = restoredPolicy
                if !displacedWasSuspended, let recovery = recoveryHandlers[.tts] {
                    await recovery()
                }
            } else {
                policy = AudioSessionPolicy()
            }
        } else if !applied, displacedMode == .voice {
            policy = AudioSessionPolicy()
            try? configurator.setActive(false, notifyOthers: true)
        }
        Log.event("audio.session.mode", level: applied ? .info : .error, data: [
            "mode": policy.mode.rawValue,
            "success": String(applied),
        ])
        return applied
    }

    /// Release a mode. Only the current owner can release — calling
    /// `releaseActiveMode(.tts)` while the coordinator is in `.voice` is a
    /// no-op (prevents TTS from accidentally evicting voice chat).
    public func releaseActiveMode(_ mode: ActiveMode) async {
        switch mode {
        case .idle:
            return
        case .tts:
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.endPlayback)) { policy = nextPolicy }
        case .voice:
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.endVoice)) { policy = nextPolicy }
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
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.interrupted)) { policy = nextPolicy }
            Log.event("audio.interruption", level: .info, data: ["event": "began"])
        case .endedShouldResume:
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.resume)) { policy = nextPolicy }
            Log.event("audio.interruption", level: .info, data: ["event": "ended.shouldResume"])
        case .endedNoResume:
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.endInterruptionNoResume)) { policy = nextPolicy }
            Log.event("audio.interruption", level: .info, data: ["event": "ended.noResume"])
        }
    }

    private func handleRouteChange(_ event: AudioRouteChangeEvent) async {
        switch event {
        case .oldDeviceUnavailable:
            if policy.mode == .tts { await suspend(.tts) }
            var nextPolicy = policy
            if apply(nextPolicy.reduce(.routeUnavailable)) { policy = nextPolicy }
            Log.event("audio.route.changed", level: .info, data: ["event": "oldDeviceUnavailable"])
        case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep, .noSuitableRoute, .unknown:
            // A route becoming available must not implicitly resume narration.
            // The active reader can explicitly request `.tts` to resume.
            Log.event("audio.route.changed", level: .debug, data: ["event": String(describing: event)])
        }
    }
}

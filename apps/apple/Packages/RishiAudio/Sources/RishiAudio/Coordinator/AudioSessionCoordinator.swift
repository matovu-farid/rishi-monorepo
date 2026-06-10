import Foundation
import RishiLogging

/// Shared actor that owns the singleton AVAudioSession configuration on
/// behalf of TTS (Phase 8) and Voice Chat (Phase 10). Only ONE active mode
/// at a time — requesting `.voice` while `.tts` is active tears down TTS's
/// configuration first.
///
/// Pitfall 8 + Pitfall (voice/spokenAudio mode): centralise here so subsystem
/// code never touches AVAudioSession directly.
public actor AudioSessionCoordinator {

    private let configurator: any AudioSessionConfigurator
    private var _currentMode: ActiveMode = .idle
    private var _isSuspended = false
    private var interruptionTask: Task<Void, Never>?

    public init(configurator: any AudioSessionConfigurator) {
        self.configurator = configurator
        Task { await self.startInterruptionLoop() }
    }

    deinit {
        interruptionTask?.cancel()
    }

    public var currentMode: ActiveMode { _currentMode }
    public var isSuspended: Bool { _isSuspended }

    /// Request the coordinator switch (or stay in) the given mode. Returns
    /// after the underlying configurator has finished its work.
    public func requestActiveMode(_ mode: ActiveMode) async {
        guard mode != .idle else { return }
        guard mode != _currentMode || _isSuspended else { return }

        // If a different mode currently owns the session, tear it down first.
        if _currentMode != .idle, _currentMode != mode {
            try? configurator.setActive(false, notifyOthers: true)
        }

        do {
            switch mode {
            case .tts:
                try configurator.configure(
                    category: .playback,
                    mode: .spokenAudio,
                    options: [.allowBluetooth, .allowAirPlay]
                )
            case .voice:
                try configurator.configure(
                    category: .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetooth]
                )
            case .idle:
                break // already filtered above
            }
            try configurator.setActive(true, notifyOthers: false)
            _currentMode = mode
            _isSuspended = false
            Log.event("audio.session.mode", level: .info, data: ["mode": mode.rawValue])
        } catch {
            Log.event("audio.session.mode.failed", level: .error, data: [
                "mode": mode.rawValue,
                "error": String(describing: error),
            ])
        }
    }

    /// Release a mode. Only the current owner can release — calling
    /// `releaseActiveMode(.tts)` while the coordinator is in `.voice` is a
    /// no-op (prevents TTS from accidentally evicting voice chat).
    public func releaseActiveMode(_ mode: ActiveMode) async {
        guard _currentMode == mode else { return }
        try? configurator.setActive(false, notifyOthers: true)
        _currentMode = .idle
        _isSuspended = false
        Log.event("audio.session.mode", level: .info, data: ["mode": ActiveMode.idle.rawValue])
    }

    // MARK: - Interruption handling

    private func startInterruptionLoop() async {
        let stream = configurator.interruptionStream()
        interruptionTask = Task { [weak self] in
            for await event in stream {
                await self?.handleInterruption(event)
            }
        }
    }

    private func handleInterruption(_ event: AudioInterruptionEvent) async {
        switch event {
        case .began:
            _isSuspended = true
            Log.event("audio.interruption", level: .info, data: ["event": "began"])
        case .endedShouldResume:
            guard _currentMode != .idle else { return }
            try? configurator.setActive(true, notifyOthers: false)
            _isSuspended = false
            Log.event("audio.interruption", level: .info, data: ["event": "ended.shouldResume"])
        case .endedNoResume:
            _currentMode = .idle
            _isSuspended = false
            Log.event("audio.interruption", level: .info, data: ["event": "ended.noResume"])
        }
    }
}

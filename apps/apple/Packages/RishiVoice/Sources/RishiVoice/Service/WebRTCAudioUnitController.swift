import Foundation
import RishiLogging

// WebRTC's `RTCAudioSession` (LiveKit-prefixed `LKRTCAudioSession`) wraps
// `AVAudioSession` and exists ONLY on iOS / macCatalyst — the macOS slice of
// the LiveKitWebRTC xcframework ships neither the header nor the class. Plain
// macOS voice chat is not a shipping path (the app targets iPhone), so gate the
// manual-audio control to the platforms where the symbol is real. Without this
// guard `swift build` on a macOS host (which picks the macos-* slice) fails
// with "cannot find 'LKRTCAudioSession' in scope".
#if !os(macOS) || targetEnvironment(macCatalyst)
import LiveKitWebRTC
#endif

/// Owns the process-global WebRTC audio-unit control that `RealtimeAPIAdapter`
/// previously inlined. Single responsibility: flip WebRTC's manual-audio mode
/// + the VoIP audio unit on/off, with the macOS platform gating in one place.
///
/// Stateless (the state lives in the process-global `LKRTCAudioSession`
/// singleton), so it is trivially `Sendable`. The adapter holds one instance
/// and calls `enableManualModeOnce()` + `enableAudioUnit()` on connect and
/// `disableAudioUnit()` on full disconnect — exactly the prior call sites.
struct WebRTCAudioUnitController: Sendable {

    /// One-time, process-global enable of WebRTC's MANUAL audio mode.
    ///
    /// WebRTC's audio I/O unit lives in the process-global `LKRTCAudioSession`
    /// singleton (the LiveKit-prefixed `RTCAudioSession`). In WebRTC's default
    /// AUTOMATIC mode the VoIP audio unit is initialized once when the first
    /// peer's audio track is ready; when session 1's peer closes WebRTC tears
    /// the unit down, and session 2's fresh peer does NOT re-initialize it —
    /// so session 2 reaches `.live` with dead mic + playout (user speaks, no
    /// reply). Switching to MANUAL mode hands us deterministic control: WebRTC
    /// will only (re)initialize the audio unit when we flip `isAudioEnabled`
    /// true, which we do on every `connect()` (and false on full `disconnect()`).
    ///
    /// `useManualAudio` is a plain settable `BOOL` property; per the header it
    /// does NOT require `lockForConfiguration` (that lock guards only
    /// `setConfiguration:`/`setActive:`). A `static let` runs its initializer
    /// exactly once and is thread-safe, giving the idempotent one-time set.
    private static let _enableManualAudioOnce: Void = {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        LKRTCAudioSession.sharedInstance().useManualAudio = true
        #endif
    }()

    /// Ensure WebRTC manual-audio mode is on exactly once (process-global,
    /// idempotent), BEFORE any WebRTC audio init.
    func enableManualModeOnce() {
        _ = Self._enableManualAudioOnce
    }

    /// Permit WebRTC to (re)initialize the VoIP audio unit. In manual mode this
    /// is what actually starts mic capture + playout — and it re-runs on EVERY
    /// connect, fixing the dead-audio on session 2+ where the auto-mode unit had
    /// been torn down and never re-created.
    func enableAudioUnit() {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        LKRTCAudioSession.sharedInstance().isAudioEnabled = true
        Log.event("voice.audio.unit.enabled", level: .info, data: ["enabled": "true"])
        #endif
    }

    /// Stop + uninitialize WebRTC's VoIP audio unit on FULL session end so the
    /// next session's connect() forces a clean re-init. Deliberately NOT done on
    /// the in-session RECONNECT teardown path, where disabling audio would kill
    /// a live reconnect — only full `disconnect()` flips it false.
    func disableAudioUnit() {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        LKRTCAudioSession.sharedInstance().isAudioEnabled = false
        Log.event("voice.audio.unit.enabled", level: .info, data: ["enabled": "false"])
        #endif
    }
}

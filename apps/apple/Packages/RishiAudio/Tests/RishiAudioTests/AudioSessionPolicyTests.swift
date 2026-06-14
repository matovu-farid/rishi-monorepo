import Testing
@testable import RishiAudio

@Suite("AudioSessionPolicy")
struct AudioSessionPolicyTests {

    private var ttsConfigure: AudioSessionEffect {
        .configure(category: .playback, mode: .spokenAudio, options: [.allowBluetooth, .allowAirPlay])
    }
    private var voiceConfigure: AudioSessionEffect {
        .configure(category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
    }

    @Test("From idle, beginPassage configures TTS and activates")
    func beginPassageFromIdle() {
        var policy = AudioSessionPolicy()
        let effects = policy.reduce(.beginPassage)
        #expect(effects == [ttsConfigure, .activate])
        #expect(policy.mode == .tts)
    }

    @Test("switchPassage while tts emits no effects (no churn)")
    func switchPassageNoChurn() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.switchPassage)
        #expect(effects == [])
        #expect(policy.mode == .tts)
    }

    @Test("endPlayback while tts deactivates and goes idle")
    func endPlaybackFromTTS() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.endPlayback)
        #expect(effects == [.deactivate(notifyOthers: true)])
        #expect(policy.mode == .idle)
    }

    @Test("From idle, beginVoice configures voice and activates")
    func beginVoiceFromIdle() {
        var policy = AudioSessionPolicy()
        let effects = policy.reduce(.beginVoice)
        #expect(effects == [voiceConfigure, .activate])
        #expect(policy.mode == .voice)
    }

    @Test("beginVoice while tts tears down tts first then configures voice")
    func beginVoiceWhileTTS() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.beginVoice)
        #expect(effects == [.deactivate(notifyOthers: true), voiceConfigure, .activate])
        #expect(policy.mode == .voice)
    }

    @Test("interrupted while tts suspends, no effects, mode unchanged")
    func interruptedWhileTTS() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.interrupted)
        #expect(effects == [])
        #expect(policy.isSuspended == true)
        #expect(policy.mode == .tts)
    }

    @Test("resume after interruption while tts re-activates")
    func resumeAfterInterruption() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        _ = policy.reduce(.interrupted)
        let effects = policy.reduce(.resume)
        #expect(effects == [.activate])
        #expect(policy.isSuspended == false)
        #expect(policy.mode == .tts)
    }

    @Test("endInterruptionNoResume drops to idle")
    func endInterruptionNoResumeDropsIdle() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.endInterruptionNoResume)
        #expect(effects == [])
        #expect(policy.mode == .idle)
    }

    @Test("beginPassage while tts and suspended reconfigures and activates")
    func beginPassageWhileSuspended() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        _ = policy.reduce(.interrupted)
        let effects = policy.reduce(.beginPassage)
        #expect(effects == [ttsConfigure, .activate])
        #expect(policy.mode == .tts)
        #expect(policy.isSuspended == false)
    }

    @Test("switchPassage while tts and suspended reconfigures and activates")
    func switchPassageWhileSuspended() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        _ = policy.reduce(.interrupted)
        let effects = policy.reduce(.switchPassage)
        #expect(effects == [ttsConfigure, .activate])
        #expect(policy.mode == .tts)
        #expect(policy.isSuspended == false)
    }

    @Test("endPlayback while idle is a no-op")
    func endPlaybackWhileIdle() {
        var policy = AudioSessionPolicy()
        let effects = policy.reduce(.endPlayback)
        #expect(effects == [])
        #expect(policy.mode == .idle)
    }

    @Test("endVoice while tts is a no-op (wrong owner)")
    func endVoiceWhileTTS() {
        var policy = AudioSessionPolicy()
        _ = policy.reduce(.beginPassage)
        let effects = policy.reduce(.endVoice)
        #expect(effects == [])
        #expect(policy.mode == .tts)
    }

    @Test("switchPassage from idle starts a fresh TTS passage")
    func switchPassageFromIdle() {
        var policy = AudioSessionPolicy()
        let effects = policy.reduce(.switchPassage)
        #expect(effects == [ttsConfigure, .activate])
        #expect(policy.mode == .tts)
    }
}

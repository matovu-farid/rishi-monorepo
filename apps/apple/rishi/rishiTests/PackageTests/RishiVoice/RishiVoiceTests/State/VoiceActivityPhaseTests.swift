@testable import rishi
import Testing


@MainActor
@Suite("VoiceActivityPhase")
struct VoiceActivityPhaseTests {

    @Test("apply(status:) maps pre-live statuses to connecting")
    func connectingStatuses() {
        let s = VoiceSessionState()
        for status: VoiceSessionStatus in [
            .idle,
            .requestingMic,
            .fetchingKey,
            .creatingSession,
            .connecting,
            .registeringCall,
        ] {
            s.apply(status: status)
            #expect(s.activityPhase == .connecting)
        }
    }

    @Test("apply(status:) maps live to listening")
    func liveMapsToListening() {
        let s = VoiceSessionState()
        s.apply(status: .live)
        #expect(s.activityPhase == .listening)
    }

    @Test("apply(status:) maps reconnecting to reconnecting")
    func reconnectingStatus() {
        let s = VoiceSessionState()
        s.apply(status: .reconnecting(attempt: 2))
        #expect(s.activityPhase == .reconnecting)
    }

    @Test("apply(activityPhase:) updates observable phase")
    func applyActivityPhase() {
        let s = VoiceSessionState()
        s.apply(activityPhase: .speaking)
        #expect(s.activityPhase == .speaking)
    }

    @Test("reset clears activityPhase to connecting")
    func resetClearsPhase() {
        let s = VoiceSessionState()
        s.apply(activityPhase: .speaking)
        s.reset()
        #expect(s.activityPhase == .connecting)
    }
}

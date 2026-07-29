@testable import rishi
import Testing
import SwiftUI


@MainActor
@Suite("VoiceControlsView")
struct VoiceControlsViewTests {

    @Test("VoiceControlsView constructs for every activityPhase")
    func constructsAllPhases() {
        for phase in [VoiceActivityPhase.connecting, .listening, .speaking, .reconnecting] {
            let state = VoiceSessionState()
            state.apply(status: .live)
            state.apply(activityPhase: phase)
            _ = VoiceControlsView(state: state, onEnd: {}, onOpenReadAloud: {}).body
        }
    }

    @Test("VoiceControlsView constructs when isFinalInterval")
    func endingSoonLabel() {
        let state = VoiceSessionState()
        state.apply(status: .live)
        state.applySessionEndingWarning()
        _ = VoiceControlsView(state: state, onEnd: {}, onOpenReadAloud: {}).body
    }

    @Test("VoiceControlsView constructs with onOpenTextChat hook")
    func constructsWithTextChat() {
        let state = VoiceSessionState()
        state.apply(status: .live)
        _ = VoiceControlsView(
            state: state,
            onEnd: {},
            onOpenReadAloud: {},
            onOpenTextChat: {}
        ).body
    }

    @Test("VoiceControlsView exposes stable accessibility identifiers")
    func accessibilityIdentifiers() {
        #expect(VoiceControlsView.openReadAloudAccessibilityIdentifier == "voice-open-read-aloud")
        #expect(VoiceControlsView.endAccessibilityIdentifier == "voice-end")
        #expect(VoiceControlsView.openTextChatAccessibilityIdentifier == "voice.openTextChat")
    }

    @Test("VoiceControlsView uses a stable icon-button hit target")
    func iconButtonHitTarget() {
        #expect(VoiceControlsView.iconButtonSize == 48)
    }

    @Test("VoiceControlsView constructs across connecting statuses")
    func connectingStatuses() {
        let statuses: [VoiceSessionStatus] = [
            .connecting,
            .creatingSession,
            .registeringCall,
            .reconnecting(attempt: 1),
        ]
        for status in statuses {
            let state = VoiceSessionState()
            state.apply(status: status)
            _ = VoiceControlsView(state: state, onEnd: {}, onOpenReadAloud: {}).body
        }
    }

    @Test("pre-live statuses use the compact progress visual")
    func preLiveStatusesUseProgressVisual() {
        for status in [
            VoiceSessionStatus.idle,
            .requestingMic,
            .fetchingKey,
            .creatingSession,
            .connecting,
            .registeringCall,
        ] {
            #expect(VoiceControlsView.usesProgressVisual(for: status))
        }

        #expect(!VoiceControlsView.usesProgressVisual(for: .live))
        #expect(!VoiceControlsView.usesProgressVisual(for: .reconnecting(attempt: 1)))
    }

    @Test("live confirmation cue plays only on the first transition to live")
    func liveConfirmationCuePolicy() {
        #expect(VoiceControlsView.shouldPlayLiveConfirmation(
            from: .connecting,
            to: .live,
            hasPlayed: false
        ))
        #expect(!VoiceControlsView.shouldPlayLiveConfirmation(
            from: .reconnecting(attempt: 1),
            to: .live,
            hasPlayed: false
        ))
        #expect(!VoiceControlsView.shouldPlayLiveConfirmation(
            from: .live,
            to: .live,
            hasPlayed: false
        ))
        #expect(!VoiceControlsView.shouldPlayLiveConfirmation(
            from: .connecting,
            to: .live,
            hasPlayed: true
        ))
        #expect(!VoiceControlsView.shouldPlayLiveConfirmation(
            from: nil,
            to: .live,
            hasPlayed: false
        ))
    }
}

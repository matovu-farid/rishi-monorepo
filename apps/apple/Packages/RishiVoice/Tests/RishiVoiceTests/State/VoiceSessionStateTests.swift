import Testing
import Foundation
@testable import RishiVoice

@MainActor
@Suite("VoiceSessionState")
struct VoiceSessionStateTests {

    @Test("Initial state is idle with empty transcripts")
    func initialState() {
        let s = VoiceSessionState()
        #expect(s.status == .idle)
        #expect(s.partialUserTranscript == "")
        #expect(s.partialAssistantTranscript == "")
        #expect(s.lastError == nil)
    }

    @Test("apply(status:) updates the observable status")
    func applyStatus() {
        let s = VoiceSessionState()
        s.apply(status: .live)
        #expect(s.status == .live)
        s.apply(status: .reconnecting(attempt: 2))
        #expect(s.status == .reconnecting(attempt: 2))
    }

    @Test("appendTranscript accumulates per role")
    func appendTranscriptPerRole() {
        let s = VoiceSessionState()
        s.appendTranscript(role: .assistant, content: "Hel")
        s.appendTranscript(role: .assistant, content: "lo")
        s.appendTranscript(role: .user, content: "Hi")
        #expect(s.partialAssistantTranscript == "Hello")
        #expect(s.partialUserTranscript == "Hi")
    }

    @Test("clearTranscript clears only the given role")
    func clearTranscriptForRole() {
        let s = VoiceSessionState()
        s.appendTranscript(role: .assistant, content: "x")
        s.appendTranscript(role: .user, content: "y")
        s.clearTranscript(role: .assistant)
        #expect(s.partialAssistantTranscript == "")
        #expect(s.partialUserTranscript == "y")
    }

    @Test("reset returns state to initial")
    func resetReturnsToInitial() {
        let s = VoiceSessionState()
        s.apply(status: .live)
        s.appendTranscript(role: .assistant, content: "x")
        s.recordError("boom")
        s.reset()
        #expect(s.status == .idle)
        #expect(s.partialAssistantTranscript == "")
        #expect(s.lastError == nil)
    }
}

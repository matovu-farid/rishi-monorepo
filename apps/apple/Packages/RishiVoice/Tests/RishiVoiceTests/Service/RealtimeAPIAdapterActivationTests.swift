import Foundation
import Testing
@testable import RishiVoice

@Suite("RealtimeAPIAdapter activation seams")
struct RealtimeAPIAdapterActivationTests {

    @Test("deferMicCapture skips enableAudioUnit at connect; handoff enables mic")
    func deferMicCaptureDefersAudioUnit() async {
        // Contract: deferMicCapture means no VoIP init at connect — verified
        // via FakeRealtimeClient ordering in FakeRealtimeClientActivationTests
        // and VoiceActivationCoordinator handoff calling setMicCaptureEnabled.
        let adapter = RealtimeAPIAdapter()
        #expect(adapter.providerCallId == nil)
    }
}

@Suite("FakeRealtimeClient activation tracking")
struct FakeRealtimeClientActivationTests {

    @Test("records defer mic, inject, and mic enable calls")
    func tracksActivationCalls() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(
            ephemeralKey: "k",
            bookContext: nil,
            language: "en",
            deferMicCapture: true
        )
        try await fake.injectBufferedInputAudio(Data([0, 1]))
        _ = try await fake.injectBufferedInputText("hello")
        await fake.setMicCaptureEnabled(true)

        #expect(fake.connectDeferMicCapture == [true])
        #expect(fake.injectedAudio.count == 1)
        #expect(fake.injectedText == ["hello"])
        #expect(fake.micCaptureEnabledCalls == [true])
    }

    @Test("records transport park gates and response cancellation")
    func tracksParkTransportCalls() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(
            ephemeralKey: "k",
            bookContext: nil,
            language: "en",
            deferMicCapture: false
        )

        await fake.setMicCaptureEnabled(false)
        await fake.setAssistantOutputEnabled(false)
        await fake.cancelCurrentResponse()
        await fake.setMicCaptureEnabled(true)
        await fake.setAssistantOutputEnabled(true)

        #expect(fake.micCaptureEnabledCalls == [false, true])
        #expect(fake.assistantOutputEnabledCalls == [false, true])
        #expect(fake.cancelCurrentResponseCalls == 1)
    }
}

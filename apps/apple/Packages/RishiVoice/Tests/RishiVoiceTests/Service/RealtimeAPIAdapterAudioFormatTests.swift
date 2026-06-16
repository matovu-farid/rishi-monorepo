import Testing
import RealtimeAPI
@testable import RishiVoice

/// Regression: the OpenAI Realtime API rejects a bare `"pcm"` audio format
/// type ("Invalid value: 'pcm'. Supported values are: 'audio/pcm', 'audio/pcmu',
/// and 'audio/pcma'."). A rejected `session.update` leaves the session
/// non-functional and triggers an endless reconnect loop (the user hears
/// nothing back). The format MUST use the MIME-style `"audio/pcm"` at 24kHz.
@Suite("RealtimeAPIAdapter audio format")
struct RealtimeAPIAdapterAudioFormatTests {

    @Test("input/output format uses the OpenAI-required audio/pcm type at 24kHz")
    func usesAudioPcmMimeType() {
        let format = RealtimeAPIAdapter.makePCM24kFormat()
        #expect(format.type == "audio/pcm")
        #expect(format.rate == 24000)
    }

    @Test("server-side input noise reduction is set per platform")
    func inputNoiseReductionIsPlatformAppropriate() {
        // Mobile (held phone / headset) -> near-field; laptop/desktop
        // built-in mic used hands-free -> far-field. Must never be unset.
        #if targetEnvironment(macCatalyst) || os(macOS)
        #expect(RealtimeAPIAdapter.inputNoiseReduction == .farField)
        #else
        #expect(RealtimeAPIAdapter.inputNoiseReduction == .nearField)
        #endif
    }
}

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
}

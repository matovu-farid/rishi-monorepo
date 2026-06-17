import Foundation
import RealtimeAPI

/// Builds the OpenAI Realtime `Session.Audio` configuration that
/// `RealtimeAPIAdapter` previously inlined in its `connect` closure. Single
/// responsibility: encode the audio format + VAD + voice + noise-reduction
/// params. Pure value type, no I/O — trivially testable.
///
/// `makePCM24kFormat` + `inputNoiseReduction` remain `static` (and `internal`)
/// so the existing `RealtimeAPIAdapterAudioFormatTests` keep pointing at the
/// same symbols via re-export shims on the adapter.
struct RealtimeSessionConfigBuilder: Sendable {

    /// PCM 24kHz audio format used for BOTH input and output.
    ///
    /// The OpenAI Realtime API requires the MIME-style type `"audio/pcm"`; a
    /// bare `"pcm"` is rejected at session-update time ("Invalid value: 'pcm'.
    /// Supported values are: 'audio/pcm', 'audio/pcmu', and 'audio/pcma'."),
    /// which leaves the session non-functional and triggers an endless
    /// reconnect loop. `Session.AudioFormat` has only an internal memberwise
    /// init, so we round-trip JSON to build it from outside the SDK module.
    static func makePCM24kFormat() -> Session.AudioFormat {
        let data = try! JSONSerialization.data(withJSONObject: [
            "rate": 24000,
            "type": "audio/pcm",
        ])
        return try! JSONDecoder().decode(Session.AudioFormat.self, from: data)
    }

    /// OpenAI server-side input noise reduction, on top of the device-side
    /// WebRTC/AVAudioSession processing. near-field suits a held phone or a
    /// headset (mobile); far-field suits a laptop/desktop built-in mic used
    /// hands-free.
    static var inputNoiseReduction: Session.Audio.Input.NoiseReduction {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .farField
        #else
        return .nearField
        #endif
    }

    /// Build the full `Session.Audio` block applied inside the SDK's
    /// `Conversation { session in ... }` builder. Voice + VAD parity with
    /// electron / Spike B (INTEGRATIONS.md:44): server VAD threshold 0.7,
    /// silence 700ms, prefix padding 300ms, voice=alloy, PCM 24kHz.
    func makeSessionAudio() -> Session.Audio {
        let pcm24k = Self.makePCM24kFormat()
        let input = Session.Audio.Input(
            format: pcm24k,
            noiseReduction: Self.inputNoiseReduction,
            transcription: nil,
            turnDetection: .serverVad(
                prefixPaddingMs: 300,
                silenceDurationMs: 700,
                threshold: 0.7
            )
        )
        let output = Session.Audio.Output(
            voice: .alloy,
            speed: 1.0,
            format: pcm24k
        )
        return Session.Audio(input: input, output: output)
    }
}

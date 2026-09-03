import Testing

@testable import rishi

@Suite("Shared reading audio ducking")
struct SharedReadingAudioDuckingTests {
    @Test("ducks local TTS only while active reading has a speaker")
    func activeSpeakerDucksTTS() {
        #expect(SharedReadingAudioDucking.ttsVolume(isTTSPlaying: true, speakerUserId: "u_speaker") == 0.25)
        #expect(SharedReadingAudioDucking.ttsVolume(isTTSPlaying: false, speakerUserId: "u_speaker") == 1)
        #expect(SharedReadingAudioDucking.ttsVolume(isTTSPlaying: true, speakerUserId: nil) == 1)
    }
}

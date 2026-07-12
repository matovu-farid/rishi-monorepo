import Foundation
import RishiAudio
import Testing

@testable import rishi

@Suite("Readium TTS prefetch coordinator")
struct ReadiumTTSPrefetchCoordinatorTests {

    @Test("prefetch window excludes current paragraph and uses active settings")
    func prefetchWindowUsesNextFiveParagraphs() {
        let settings = TTSSettings(
            voice: "alloy",
            model: "gpt-4o-mini-tts",
            speed: 1.1
        )

        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            paragraphs: ["one", "two", "three", "four", "five", "six", "seven"],
            after: "two",
            settings: settings,
            limit: 5
        )

        #expect(requests.map(\.text) == ["three", "four", "five", "six", "seven"])
        #expect(requests.allSatisfy {
            $0.voice == "alloy"
                && $0.model == "gpt-4o-mini-tts"
                && $0.speed == 1.1
        })
    }
}

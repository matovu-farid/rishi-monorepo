import Foundation
import ReadiumShared
import RishiAudio
import RishiReader
import Testing

@testable import rishi

@Suite("Readium TTS prefetch coordinator")
@MainActor
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

    @Test("uses the current token index when repeated text occurs")
    func repeatedTextUsesExplicitCurrentIndex() {
        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            paragraphs: ["repeat", "repeat", "after"],
            after: "repeat",
            currentIndex: 1,
            settings: .default,
            limit: 1
        )

        #expect(requests.map(\.text) == ["after"])
    }

    @Test("prefers current token locator over repeated text")
    func currentLocatorDisambiguatesRepeatedText() {
        let firstLocator = Locator(href: AnyURL(string: "chapter.xhtml")!, mediaType: .xhtml)
        let secondLocator = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.5)
        )
        let candidates = [
            ReadiumTTSPrefetchRequestBuilder.Candidate(text: "repeat", locator: firstLocator),
            ReadiumTTSPrefetchRequestBuilder.Candidate(text: "repeat", locator: secondLocator),
            ReadiumTTSPrefetchRequestBuilder.Candidate(text: "after", locator: nil),
        ]

        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            candidates: candidates,
            after: "repeat",
            currentLocator: secondLocator,
            settings: .default,
            limit: 1
        )

        #expect(requests.map(\.text) == ["after"])
    }

    @Test("uses paragraph granularity by default")
    func prefetchDefaultsToParagraphGranularity() {
        let coordinator = ReadiumTTSPrefetchCoordinator(
            prewarmer: TTSPrewarmer(source: NoopTTSChunkSourceForTests())
        )

        #expect(coordinator.granularity == .paragraph)
    }

    @Test("accepts the playback granularity")
    func prefetchUsesPlaybackGranularity() {
        let coordinator = ReadiumTTSPrefetchCoordinator(
            prewarmer: TTSPrewarmer(source: NoopTTSChunkSourceForTests()),
            granularity: .sentence
        )

        #expect(coordinator.granularity == .sentence)
    }
}

private struct NoopTTSChunkSourceForTests: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

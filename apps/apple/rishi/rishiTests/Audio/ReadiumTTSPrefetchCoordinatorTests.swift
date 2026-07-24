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

    @Test("preserves packed PDF sentence text as one prefetch request")
    func preservesPackedPDFChunkText() {
        let packedChunk = "First sentence crosses the visual line. Second sentence stays in the same buffer."

        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            paragraphs: ["current", packedChunk, "following"],
            after: "current",
            settings: .default,
            limit: 2
        )

        #expect(requests.map(\.text) == [packedChunk, "following"])
    }

    @Test("keeps each packed PDF chunk atomic when prefetching multiple chunks")
    func keepsPackedPDFChunksAtomic() {
        let firstChunk = "First sentence. Second sentence."
        let secondChunk = "Third sentence. Fourth sentence."

        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            paragraphs: ["current", firstChunk, secondChunk],
            after: "current",
            settings: .default,
            limit: 2
        )

        #expect(requests.count == 2)
        #expect(requests[0].text == firstChunk)
        #expect(requests[1].text == secondChunk)
    }

    @Test("does not split a 400-character packed PDF chunk")
    func doesNotSplit400CharacterPackedPDFChunk() {
        let packedChunk = String(repeating: "x", count: 399) + "."

        let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
            paragraphs: ["current", packedChunk],
            after: "current",
            settings: .default,
            limit: 1
        )

        #expect(packedChunk.count == 400)
        #expect(requests.map(\.text) == [packedChunk])
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

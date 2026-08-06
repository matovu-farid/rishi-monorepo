import Foundation
import ReadiumNavigator
import ReadiumShared




/// Builds the requests immediately after the token currently being spoken.
/// Keeping this separate makes the prefetch window deterministic and testable.
enum ReadiumTTSPrefetchRequestBuilder {
    struct Candidate {
        let text: String
        let locator: Locator?

        nonisolated init(text: String, locator: Locator? = nil) {
            self.text = text
            self.locator = locator
        }
    }

    /// Matches `workers/worker` `TTS_MAX_CHARS_PER_REQUEST` and CustomTTSEngine.
    static let maxCharsPerRequest = 4000

    static func makeRequests(
        paragraphs: [String],
        after currentParagraph: String,
        currentIndex: Int? = nil,
        settings: TTSSettings,
        limit: Int
    ) -> [TTSStreamRequest] {
        makeRequests(
            candidates: paragraphs.map { Candidate(text: $0) },
            after: currentParagraph,
            currentIndex: currentIndex,
            settings: settings,
            limit: limit
        )
    }

    static func makeRequests(
        candidates: [Candidate],
        after currentParagraph: String,
        currentLocator: Locator? = nil,
        currentIndex: Int? = nil,
        settings: TTSSettings,
        limit: Int
    ) -> [TTSStreamRequest] {
        guard limit > 0, !candidates.isEmpty else { return [] }

        let currentTokenIndex = currentLocator.flatMap { locator in
            candidates.firstIndex { $0.locator == locator }
        } ?? currentIndex ?? candidates.firstIndex { $0.text == currentParagraph }
        let startIndex = currentTokenIndex.map { $0 + 1 } ?? 0
        var requests: [TTSStreamRequest] = []
        for candidate in candidates.dropFirst(startIndex) {
            let pieces = ParagraphChunker.chunkForTTS(
                candidate.text,
                maxChars: maxCharsPerRequest
            )
            for piece in pieces where !piece.isEmpty {
                requests.append(
                    TTSStreamRequest(
                        text: piece,
                        voice: settings.voice,
                        model: settings.model,
                        speed: settings.speed
                    )
                )
                if requests.count >= limit { return requests }
            }
        }
        return requests
    }
}

/// Discovers future Readium tokens and asks the shared prewarmer to fill
/// the existing TTS cache. The synthesizer remains unaware of this work and
/// continues to request audio through its normal engine path.
@MainActor
final class ReadiumTTSPrefetchCoordinator {
    static let defaultGranularity: CustomTTSTokenizer.Granularity = .paragraph

    private let prewarmer: TTSPrewarmer
    private let readAheadCount: Int
    let granularity: CustomTTSTokenizer.Granularity
    private var discoveryTask: Task<Void, Never>?
    private var generation: UInt = 0

    init(
        prewarmer: TTSPrewarmer,
        readAheadCount: Int = 5,
        granularity: CustomTTSTokenizer.Granularity = .paragraph
    ) {
        self.prewarmer = prewarmer
        self.readAheadCount = readAheadCount
        self.granularity = granularity
    }

    func update(
        publication: Publication,
        utterance: PublicationSpeechSynthesizer.Utterance,
        settings: TTSSettings
    ) {
        let previousDiscoveryTask = discoveryTask
        previousDiscoveryTask?.cancel()
        generation &+= 1
        let generation = self.generation

        let prewarmer = self.prewarmer
        let readAheadCount = self.readAheadCount
        let granularity = self.granularity
        discoveryTask = Task { [weak self] in
            guard let self else { return }

            do {
                // Serialize replacement with the previous scan. This also
                // ensures any requests it launched are cleared before the
                // new utterance starts warming the cache.
                await previousDiscoveryTask?.value
                guard !Task.isCancelled, self.generation == generation else { return }

                let candidates = try await self.candidates(
                    in: publication,
                    startingAt: utterance.locator,
                    granularity: granularity
                )
                guard !Task.isCancelled, self.generation == generation else { return }

                let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
                    candidates: candidates,
                    after: utterance.text,
                    currentLocator: utterance.locator,
                    currentIndex: 0,
                    settings: settings,
                    limit: readAheadCount
                )
                guard !Task.isCancelled, self.generation == generation else { return }
                await prewarmer.warm(requests: requests)
            } catch is CancellationError {
                // Navigation, pause/stop, or a settings change superseded the scan.
            } catch {
                // Prefetch is best-effort. Playback can still fetch on demand.
            }
        }
    }

    /// Cancels discovery and any requests currently draining into the cache.
    func stop() async {
        generation &+= 1
        discoveryTask?.cancel()
        await discoveryTask?.value
        discoveryTask = nil
        await prewarmer.cancelAll()
    }

    nonisolated private func candidates(
        in publication: Publication,
        startingAt locator: Locator,
        granularity: CustomTTSTokenizer.Granularity
    ) async throws -> [ReadiumTTSPrefetchRequestBuilder.Candidate] {
        guard let content = publication.content(from: locator) else { return [] }
        let tokenizer = CustomTTSTokenizer.tokenize(
            defaultLanguage: publication.metadata.language,
            granularity: granularity
        )

        var candidates: [ReadiumTTSPrefetchRequestBuilder.Candidate] = []
        for await element in content.sequence() {
            guard !Task.isCancelled else { break }
            for token in try tokenizer(element) {
                switch token {
                case let textElement as TextContentElement:
                    candidates.append(contentsOf: textElement.segments.compactMap { segment in
                        Self.readableText(segment.text).map {
                            ReadiumTTSPrefetchRequestBuilder.Candidate(
                                text: $0,
                                locator: segment.locator
                            )
                        }
                    })
                case let textualElement as TextualContentElement:
                    if let text = Self.readableText(textualElement.text) {
                        candidates.append(.init(text: text))
                    }
                default:
                    continue
                }
            }
        }
        return candidates
    }

    nonisolated private static func readableText(_ text: String?) -> String? {
        guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return text
    }
}

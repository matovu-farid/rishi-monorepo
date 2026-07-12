import Foundation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiReader

/// Builds the requests immediately after the paragraph currently being spoken.
/// Keeping this separate makes the prefetch window deterministic and testable.
enum ReadiumTTSPrefetchRequestBuilder {
    static func makeRequests(
        paragraphs: [String],
        after currentParagraph: String,
        settings: TTSSettings,
        limit: Int
    ) -> [TTSStreamRequest] {
        guard limit > 0, !paragraphs.isEmpty else { return [] }

        let startIndex = paragraphs.firstIndex(of: currentParagraph).map { $0 + 1 } ?? 0
        return paragraphs.dropFirst(startIndex).prefix(limit).map { paragraph in
            TTSStreamRequest(
                text: paragraph,
                voice: settings.voice,
                model: settings.model,
                speed: settings.speed
            )
        }
    }
}

/// Discovers future Readium paragraphs and asks the shared prewarmer to fill
/// the existing TTS cache. The synthesizer remains unaware of this work and
/// continues to request audio through its normal engine path.
@MainActor
final class ReadiumTTSPrefetchCoordinator {
    private let prewarmer: TTSPrewarmer
    private let readAheadCount: Int
    private var discoveryTask: Task<Void, Never>?

    init(prewarmer: TTSPrewarmer, readAheadCount: Int = 5) {
        self.prewarmer = prewarmer
        self.readAheadCount = readAheadCount
    }

    func update(
        publication: Publication,
        utterance: PublicationSpeechSynthesizer.Utterance,
        settings: TTSSettings
    ) {
        discoveryTask?.cancel()

        let prewarmer = self.prewarmer
        let readAheadCount = self.readAheadCount
        discoveryTask = Task { [weak self] in
            guard let self else { return }

            do {
                let paragraphs = try await self.paragraphs(
                    in: publication,
                    startingAt: utterance.locator
                )
                guard !Task.isCancelled else { return }

                let requests = ReadiumTTSPrefetchRequestBuilder.makeRequests(
                    paragraphs: paragraphs,
                    after: utterance.text,
                    settings: settings,
                    limit: readAheadCount
                )
                guard !Task.isCancelled else { return }
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
        discoveryTask?.cancel()
        discoveryTask = nil
        await prewarmer.cancelAll()
    }

    nonisolated private func paragraphs(
        in publication: Publication,
        startingAt locator: Locator
    ) async throws -> [String] {
        guard let content = publication.content(from: locator) else { return [] }
        let tokenizer = CustomTTSTokenizer.tokenize(
            defaultLanguage: publication.metadata.language
        )

        var paragraphs: [String] = []
        for await element in content.sequence() {
            guard !Task.isCancelled else { break }
            for token in try tokenizer(element) {
                switch token {
                case let textElement as TextContentElement:
                    paragraphs.append(contentsOf: textElement.segments.compactMap { segment in
                        Self.readableText(segment.text)
                    })
                case let textualElement as TextualContentElement:
                    if let text = Self.readableText(textualElement.text) {
                        paragraphs.append(text)
                    }
                default:
                    continue
                }
            }
        }
        return paragraphs
    }

    nonisolated private static func readableText(_ text: String?) -> String? {
        guard let text, text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return text
    }
}

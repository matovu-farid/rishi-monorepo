import Foundation

@MainActor
final class AppSpeechCatalogRefreshCoordinator {

    typealias Loader = @Sendable () async throws -> SpeechOptionsEndpoint.SpeechOptionsResponse

    private let store: TTSPickerCatalogStore
    private let loader: Loader
    private let isSuppressed: @Sendable () -> Bool
    private var refreshTask: Task<Void, Never>?

    init(
        store: TTSPickerCatalogStore,
        loader: @escaping Loader,
        isSuppressed: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store
        self.loader = loader
        self.isSuppressed = isSuppressed
    }

    func start() {
        guard refreshTask == nil else { return }

        let loader = self.loader
        let isSuppressed = self.isSuppressed
        refreshTask = Task(priority: .utility) { [weak self] in
            guard !isSuppressed(), !Task.isCancelled else { return }

            do {
                let response = try await loader()
                guard !Task.isCancelled,
                      let catalog = Self.usableCatalog(from: response),
                      let self else { return }
                self.store.catalog = catalog
            } catch {
                // Keep the current catalog when optional enrichment is unavailable.
            }
        }
    }

    func cancel() {
        refreshTask?.cancel()
    }

    func waitForCurrentRefresh() async {
        await refreshTask?.value
    }

    private static func usableCatalog(
        from response: SpeechOptionsEndpoint.SpeechOptionsResponse
    ) -> TTSPickerCatalog? {
        let voiceIDs = response.voices.map(\.id)
        guard !voiceIDs.isEmpty,
              voiceIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(voiceIDs).count == voiceIDs.count,
              voiceIDs.contains(response.defaultVoiceID) else { return nil }

        return TTSPickerCatalog(
            voiceChoices: response.voices.map { TTSVoiceChoice(id: $0.id, name: $0.name) },
            defaultVoiceID: response.defaultVoiceID
        )
    }
}

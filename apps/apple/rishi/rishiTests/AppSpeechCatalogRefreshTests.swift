import Foundation
import Testing

@testable import rishi

@MainActor
@Suite("App-owned speech catalog refresh")
struct AppSpeechCatalogRefreshTests {

    @Test("repeated starts share one refresh")
    func repeatedStartsShareOneRefresh() async {
        let store = TTSPickerCatalogStore()
        let gate = SpeechOptionsLoaderGate()
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { try await gate.load() }
        )

        coordinator.start()
        coordinator.start()
        await gate.waitUntilStarted()

        #expect(store.catalog == .fallback)
        #expect(await gate.callCount == 1)

        await gate.succeed(with: response(voiceID: "server-voice"))
        await coordinator.waitForCurrentRefresh()
        coordinator.start()
        await coordinator.waitForCurrentRefresh()

        #expect(await gate.callCount == 1)
        #expect(store.catalog == catalog(voiceID: "server-voice"))
    }

    @Test("a successful response publishes to its own catalog store")
    func successUpdatesIndependentStore() async {
        let store = TTSPickerCatalogStore()
        let otherStore = TTSPickerCatalogStore()
        let response = response(voiceID: "server-voice")
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { response }
        )

        coordinator.start()
        await coordinator.waitForCurrentRefresh()

        #expect(store.catalog == catalog(voiceID: "server-voice"))
        #expect(otherStore.catalog == .fallback)
    }

    @Test("a failed request keeps the current catalog")
    func failurePreservesCurrentCatalog() async {
        let store = TTSPickerCatalogStore()
        let existing = catalog(voiceID: "existing-voice")
        store.catalog = existing
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { throw SpeechOptionsLoaderError.failed }
        )

        coordinator.start()
        await coordinator.waitForCurrentRefresh()

        #expect(store.catalog == existing)
    }

    @Test("an unusable response keeps the current catalog")
    func unusableResponsePreservesCurrentCatalog() async {
        let store = TTSPickerCatalogStore()
        let existing = catalog(voiceID: "existing-voice")
        store.catalog = existing
        let emptyResponse = SpeechOptionsEndpoint.SpeechOptionsResponse(
            provider: "openai",
            voices: [],
            models: [],
            defaultVoiceID: "missing-voice",
            defaultModelID: "model"
        )
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { emptyResponse }
        )

        coordinator.start()
        await coordinator.waitForCurrentRefresh()

        #expect(store.catalog == existing)
    }

    @Test("blank IDs, duplicate IDs, and a missing default keep the current catalog")
    func malformedNonemptyResponsesPreserveCurrentCatalog() async {
        let responses = [
            SpeechOptionsEndpoint.SpeechOptionsResponse(
                provider: "openai",
                voices: [.init(id: "  ", name: "Blank ID")],
                models: [],
                defaultVoiceID: "  ",
                defaultModelID: "model"
            ),
            SpeechOptionsEndpoint.SpeechOptionsResponse(
                provider: "openai",
                voices: [
                    .init(id: "duplicate", name: "First"),
                    .init(id: "duplicate", name: "Second")
                ],
                models: [],
                defaultVoiceID: "duplicate",
                defaultModelID: "model"
            ),
            SpeechOptionsEndpoint.SpeechOptionsResponse(
                provider: "openai",
                voices: [.init(id: "available", name: "Available")],
                models: [],
                defaultVoiceID: "missing",
                defaultModelID: "model"
            )
        ]

        for (index, response) in responses.enumerated() {
            let store = TTSPickerCatalogStore()
            let existing = catalog(voiceID: "existing-voice-\(index)")
            store.catalog = existing
            let coordinator = AppSpeechCatalogRefreshCoordinator(
                store: store,
                loader: { response }
            )

            coordinator.start()
            await coordinator.waitForCurrentRefresh()

            #expect(store.catalog == existing)
        }
    }

    @Test("a canceled request cannot publish a late response")
    func canceledLateResultIsIgnored() async {
        let store = TTSPickerCatalogStore()
        let existing = catalog(voiceID: "existing-voice")
        store.catalog = existing
        let gate = SpeechOptionsLoaderGate()
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { try await gate.load() }
        )

        coordinator.start()
        await gate.waitUntilStarted()
        coordinator.cancel()
        await gate.succeed(with: response(voiceID: "late-voice"))
        await coordinator.waitForCurrentRefresh()

        #expect(store.catalog == existing)
    }

    #if DEBUG
    @Test("real-auth UI-test mode suppresses the optional request")
    func realAuthUITestModeSuppressesRequest() async {
        let store = TTSPickerCatalogStore()
        let gate = SpeechOptionsLoaderGate()
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { try await gate.load() },
            isSuppressed: { true }
        )

        coordinator.start()
        await coordinator.waitForCurrentRefresh()

        #expect(await gate.callCount == 0)
        #expect(store.catalog == .fallback)
    }
    #endif
}

private enum SpeechOptionsLoaderError: Error {
    case failed
}

private actor SpeechOptionsLoaderGate {
    private var continuation: CheckedContinuation<SpeechOptionsEndpoint.SpeechOptionsResponse, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func load() async throws -> SpeechOptionsEndpoint.SpeechOptionsResponse {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func succeed(with response: SpeechOptionsEndpoint.SpeechOptionsResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

private func response(voiceID: String) -> SpeechOptionsEndpoint.SpeechOptionsResponse {
    SpeechOptionsEndpoint.SpeechOptionsResponse(
        provider: "openai",
        voices: [.init(id: voiceID, name: "Server Voice")],
        models: [.init(id: "model", name: "Model")],
        defaultVoiceID: voiceID,
        defaultModelID: "model"
    )
}

private func catalog(voiceID: String) -> TTSPickerCatalog {
    TTSPickerCatalog(
        voiceChoices: [.init(id: voiceID, name: "Server Voice")],
        defaultVoiceID: voiceID
    )
}

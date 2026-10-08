import Testing

@testable import rishi

@MainActor
@Suite("Speech catalog startup ordering")
struct SpeechCatalogStartupOrderingTests {

    @Test("fallback remains available after refresh starts and before the loader completes")
    func fallbackIsAvailableWhileRefreshIsSuspended() async {
        let store = TTSPickerCatalogStore()
        let gate = SuspendedSpeechOptionsLoader()
        let coordinator = AppSpeechCatalogRefreshCoordinator(
            store: store,
            loader: { try await gate.load() }
        )

        coordinator.start()
        await gate.waitUntilStarted()

        #expect(store.catalog == .fallback)

        await gate.finish()
        await coordinator.waitForCurrentRefresh()
    }
}

private actor SuspendedSpeechOptionsLoader {
    private var continuation: CheckedContinuation<SpeechOptionsEndpoint.SpeechOptionsResponse, Never>?
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func load() async -> SpeechOptionsEndpoint.SpeechOptionsResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        continuation?.resume(returning: SpeechOptionsEndpoint.SpeechOptionsResponse(
            provider: "openai",
            voices: [.init(id: "server-voice", name: "Server Voice")],
            models: [.init(id: "model", name: "Model")],
            defaultVoiceID: "server-voice",
            defaultModelID: "model"
        ))
        continuation = nil
    }
}

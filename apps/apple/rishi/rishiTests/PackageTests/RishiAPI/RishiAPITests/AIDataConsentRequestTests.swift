@testable import rishi
import Foundation
import Testing

@Suite("AI data consent request contract")
struct AIDataConsentRequestTests {
    private struct Response: Decodable, Sendable {
        let ok: Bool
    }

    private struct ConsentEndpoint: WorkerEndpoint {
        typealias Response = AIDataConsentRequestTests.Response
        let method: HTTPMethod = .POST
        let path = "/api/content"
        let requiresDataUseConsent = true
    }

    private struct AuthEndpoint: WorkerEndpoint {
        typealias Response = AIDataConsentRequestTests.Response
        let method: HTTPMethod = .GET
        let path = "/api/auth/get-session"
    }

    private struct ConsentStreamEndpoint: WorkerStreamingEndpoint {
        let method: HTTPMethod = .POST
        let path = "/api/audio/speech"
        let requiresDataUseConsent = true
    }

    private struct ConsentProvider: WorkerDataUseConsentProvider {
        let value: Bool

        func hasCurrentDataUseConsent() async -> Bool { value }
    }

    private func client(
        provider: any WorkerDataUseConsentProvider
    ) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider(nil),
            dataUseConsentProvider: provider
        )
    }

    @Test func markedNormalRequestCarriesCurrentConsentHeader() async throws {
        let client = client(provider: ConsentProvider(value: true))
        let request = try await client.buildRequest(for: ConsentEndpoint())

        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == "2026-07-29")
    }

    @Test func markedStreamingRequestCarriesCurrentConsentHeader() async throws {
        let client = client(provider: ConsentProvider(value: true))
        let request = try await client.buildStreamingRequest(for: ConsentStreamEndpoint())

        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == "2026-07-29")
    }

    @Test func unmarkedRequestNeverCarriesConsentHeader() async throws {
        let client = client(provider: ConsentProvider(value: true))
        let request = try await client.buildRequest(for: AuthEndpoint())

        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == nil)
    }

    @Test func markedRequestOmitsHeaderWhenProviderHasNoCurrentGrant() async throws {
        let client = client(provider: ConsentProvider(value: false))
        let request = try await client.buildRequest(for: ConsentEndpoint())

        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == nil)
    }

    @Test func remoteContentAndAIEndpointsAreMarkedWhileControlEndpointsAreNot() {
        #expect(RealtimeClientSecretsEndpoint().requiresDataUseConsent)
        #expect(SpeechStreamEndpoint(body: .init(text: "x", voice: "alloy")).requiresDataUseConsent)
        #expect(ElevenLabsSpeechStreamEndpoint(body: .init(text: "x", voice: "alloy")).requiresDataUseConsent)
        #expect(TranscribeEndpoint(body: .init(audio: Data(), mimeType: "audio/wav")).requiresDataUseConsent)
        #expect(CreateVoiceSessionEndpoint().requiresDataUseConsent)
        #expect(DevicesRegisterEndpoint(body: .init(
            deviceToken: String(repeating: "a", count: 64),
            platform: "ios",
            appVersion: "1.0",
            bundleId: "org.fidexa.rishi",
            topic: "org.fidexa.rishi"
        )).requiresDataUseConsent)
        #expect(SyncChangesEndpoint(since: nil).requiresDataUseConsent)
        #expect(MessagesSyncSinceEndpoint(since: nil).requiresDataUseConsent)
        #expect(ConversationsSyncSinceEndpoint(since: nil).requiresDataUseConsent)
        #expect(SpeechOptionsEndpoint().requiresDataUseConsent == false)
        #expect(GetSessionEndpoint().requiresDataUseConsent == false)
        #expect(BillingMeEndpoint().requiresDataUseConsent == false)
    }

    @Test func controlWebSocketRequestCarriesCurrentConsentHeader() async throws {
        let client = ControlWebSocketClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider(nil),
            dataUseConsentProvider: ConsentProvider(value: true),
            rishiSessionId: "session-1",
            onTerminal: { _ in }
        )
        let request = await client.buildControlRequest()

        #expect(request.url?.absoluteString == "wss://api.rishi.test/api/voice-sessions/session-1/control")
        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == "2026-07-29")
    }

    @Test func controlWebSocketRequestOmitsHeaderWithoutCurrentConsent() async throws {
        let client = ControlWebSocketClient(
            baseURL: URL(string: "https://api.rishi.test")!,
            tokenProvider: StaticTokenProvider(nil),
            dataUseConsentProvider: ConsentProvider(value: false),
            rishiSessionId: "session-1",
            onTerminal: { _ in }
        )
        let request = await client.buildControlRequest()

        #expect(request.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent") == nil)
    }
}

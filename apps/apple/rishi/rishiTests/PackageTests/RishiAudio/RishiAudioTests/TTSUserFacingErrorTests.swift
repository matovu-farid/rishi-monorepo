import Foundation
import Testing
@testable import rishi

@Suite("TTS user-facing errors")
struct TTSUserFacingErrorTests {
    @Test("classifies supported TTS failures into user-facing cases")
    func classifiesSupportedFailures() {
        #expect(
            TTSUserFacingError.classify(
                WorkerAllowanceError.trial(message: "raw trial detail")
            ) == .trialExhausted
        )
        #expect(
            TTSUserFacingError.classify(
                WorkerAllowanceError.narration(message: "raw narration detail")
            ) == .narrationExhausted
        )
        #expect(
            TTSUserFacingError.classify(WorkerDataUseConsentRequiredError())
                == .dataUseConsent
        )
        #expect(TTSUserFacingError.classify(RishiError.unauthenticated) == .authentication)
        #expect(
            TTSUserFacingError.classify(
                RishiError.networkFailure(URLError(.notConnectedToInternet))
            ) == .network
        )
        #expect(
            TTSUserFacingError.classify(
                RishiError.network(code: "http_503", message: "provider detail")
            ) == .serviceUnavailable
        )
        #expect(TTSUserFacingError.classify(CancellationError()) == nil)
    }

    @Test("sanitized copy never exposes transport or provider details")
    func sanitizedCopyHidesRawDetails() {
        let serviceFailure = TTSUserFacingError.classify(
            RishiError.network(code: "http_503", message: "provider detail")
        )
        #expect(serviceFailure?.title.isEmpty == false)
        #expect(serviceFailure?.message.isEmpty == false)
        #expect(serviceFailure?.message.contains("http_") == false)
        #expect(serviceFailure?.message.contains("Server error") == false)
        #expect(serviceFailure?.message.contains("provider detail") == false)

        let cases: [TTSUserFacingError] = [
            .trialExhausted,
            .narrationExhausted,
            .dataUseConsent,
            .authentication,
            .invalidRequest,
            .network,
            .serviceUnavailable,
            .audioPlayback,
        ]
        for failure in cases {
            #expect(failure.title.isEmpty == false)
            #expect(failure.message.isEmpty == false)
            #expect(failure.message.contains("http_") == false)
            #expect(failure.message.contains("Server error") == false)
        }
    }

    @Test("HTTP 500 is retryable and remains sanitized")
    func serverFailureIsRetryable() {
        let failure = TTSUserFacingError.classify(
            RishiError.network(code: "http_500", message: "provider internals")
        )
        #expect(failure == .serviceUnavailable)
        #expect(failure?.canRetry == true)
        #expect(failure?.message.contains("provider internals") == false)
    }
}

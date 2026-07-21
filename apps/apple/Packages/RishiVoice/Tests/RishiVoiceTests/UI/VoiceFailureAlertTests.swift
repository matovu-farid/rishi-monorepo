import Testing
@testable import RishiVoice

/// Pure-mapping tests for ``VoiceFailureAlert`` — the value the native
/// `.alert` binds to after the custom `VoiceErrorView` was removed. Asserts
/// title / message / primaryAction for every failure reason (including every
/// `KeyFetchFailure` variant) plus the caller message-override path.
///
/// Copy here MUST match the strings the deleted `VoiceErrorView` rendered so
/// the surface migration is copy-preserving.
@Suite("VoiceFailureAlert mapping")
struct VoiceFailureAlertTests {

    @Test("micDenied → Settings affordance + mic copy")
    func micDenied() {
        let alert = VoiceFailureAlert(reason: .micDenied, message: nil)
        #expect(alert.title == "Microphone access needed")
        #expect(alert.message == "Allow microphone access in Settings to talk with the AI.")
        #expect(alert.primaryAction == .openSettings)
    }

    @Test("keyFetch(.unauthorized) → sign-in copy + retry")
    func keyFetchUnauthorized() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.unauthorized), message: nil)
        #expect(alert.title == "Sign-in required")
        #expect(alert.message == "Your session expired. Sign in again to use voice chat.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("keyFetch(.subscriptionRequired) → Pro copy + retry")
    func keyFetchSubscriptionRequired() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.subscriptionRequired), message: nil)
        #expect(alert.title == "Pro required")
        #expect(alert.message == "Voice chat is a Pro feature.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("keyFetch(.serviceUnavailable) → service copy + retry")
    func keyFetchServiceUnavailable() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.serviceUnavailable), message: nil)
        #expect(alert.title == "Voice unavailable")
        #expect(alert.message == "The voice service is temporarily unavailable. Please try again soon.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("keyFetch(.network) → no-connection copy + retry")
    func keyFetchNetwork() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.network), message: nil)
        #expect(alert.title == "No connection")
        #expect(alert.message == "Check your internet connection and try again.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("keyFetch(.unknown) with detail → detail as message + retry")
    func keyFetchUnknownWithDetail() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.unknown("realtime fault")), message: nil)
        #expect(alert.title == "Couldn't start the session")
        #expect(alert.message == "realtime fault")
        #expect(alert.primaryAction == .retry)
    }

    @Test("keyFetch(.unknown) with empty detail → fallback copy + retry")
    func keyFetchUnknownEmpty() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.unknown("")), message: nil)
        #expect(alert.title == "Couldn't start the session")
        #expect(alert.message == "An unexpected error occurred.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("connect → couldn't-connect copy + retry")
    func connect() {
        let alert = VoiceFailureAlert(reason: .connect, message: nil)
        #expect(alert.title == "Couldn't connect")
        #expect(alert.message == "The voice service couldn't be reached. Try again in a moment.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("networkLost → connection-lost copy + retry")
    func networkLost() {
        let alert = VoiceFailureAlert(reason: .networkLost, message: nil)
        #expect(alert.title == "Connection lost")
        #expect(alert.message == "We lost the connection after a few retries. Try again.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("audioSession → audio-setup copy + retry")
    func audioSession() {
        let alert = VoiceFailureAlert(reason: .audioSession, message: nil)
        #expect(alert.title == "Audio setup failed")
        #expect(alert.message == "We couldn't configure audio. Make sure no other app is using the microphone.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("unknown with message → message as body + retry")
    func unknownWithMessage() {
        let alert = VoiceFailureAlert(reason: .unknown("Realtime SDK fault"), message: nil)
        #expect(alert.title == "Something went wrong")
        #expect(alert.message == "Realtime SDK fault")
        #expect(alert.primaryAction == .retry)
    }

    @Test("unknown with empty message → fallback copy + retry")
    func unknownEmpty() {
        let alert = VoiceFailureAlert(reason: .unknown(""), message: nil)
        #expect(alert.title == "Something went wrong")
        #expect(alert.message == "An unexpected error occurred.")
        #expect(alert.primaryAction == .retry)
    }

    // MARK: - Caller override

    @Test("caller-supplied message wins over default body copy")
    func messageOverrideWins() {
        let alert = VoiceFailureAlert(reason: .connect, message: "Custom override")
        #expect(alert.title == "Couldn't connect")
        #expect(alert.message == "Custom override")
        // Override does not change the affordance discriminator.
        #expect(alert.primaryAction == .retry)
    }

    @Test("caller override on micDenied keeps openSettings affordance")
    func messageOverrideKeepsAction() {
        let alert = VoiceFailureAlert(reason: .micDenied, message: "Override")
        #expect(alert.message == "Override")
        #expect(alert.primaryAction == .openSettings)
    }

    @Test("inactivityTimeout maps to inactivity copy + retry")
    func inactivityTimeoutCopy() {
        let alert = VoiceFailureAlert(
            reason: .sessionTerminated(reason: .inactivityTimeout),
            message: nil
        )
        #expect(alert.title == "Voice chat ended")
        #expect(alert.message == "Voice chat ended due to inactivity.")
        #expect(alert.primaryAction == .retry)
    }
}

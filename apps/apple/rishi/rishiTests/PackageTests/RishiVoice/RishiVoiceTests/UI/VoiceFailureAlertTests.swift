@testable import rishi
import Testing


/// Pure-mapping tests for ``VoiceFailureAlert`` — the value the native
/// `.alert` binds to after the custom `VoiceErrorView` was removed. Asserts
/// title / message / primaryAction for every failure reason (including every
/// `KeyFetchFailure` variant) plus the caller message-override path.
///
/// Copy here MUST match the strings the deleted `VoiceErrorView` rendered so
/// the surface migration is copy-preserving.
@Suite("VoiceFailureAlert mapping")
struct VoiceFailureAlertTests {
    @Test("missing data consent opens the consent flow")
    func dataUseConsentRequired() {
        let alert = VoiceFailureAlert(reason: .dataUseConsentRequired, message: nil)

        #expect(alert.title == "Data use permission needed")
        #expect(alert.message == "Allow data use to use voice chat and other AI features.")
        #expect(alert.primaryAction == .requestDataUseConsent)
    }


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

    @Test("paid allowance exhaustion uses paid copy and upgrade action")
    func paidAllowanceExhausted() {
        let alert = VoiceFailureAlert(
            reason: .sessionStart(.insufficientPaidAllowance),
            message: "raw worker detail"
        )

        #expect(alert.title == "Voice Chat allowance used up")
        #expect(alert.message == "You've used your plan's Voice Chat time for this period. Upgrade to keep using voice chat.")
        #expect(alert.primaryAction == .upgrade)
    }

    @Test("keyFetch(.unknown) with detail → safe fallback copy + retry")
    func keyFetchUnknownWithDetail() {
        let alert = VoiceFailureAlert(reason: .keyFetch(.unknown("realtime fault")), message: nil)
        #expect(alert.title == "Couldn't start the session")
        #expect(alert.message == "An unexpected error occurred.")
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

    @Test("unknown with detail → safe fallback copy + retry")
    func unknownWithMessage() {
        let alert = VoiceFailureAlert(reason: .unknown("Realtime SDK fault"), message: nil)
        #expect(alert.title == "Something went wrong")
        #expect(alert.message == "An unexpected error occurred.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("unknown with empty message → fallback copy + retry")
    func unknownEmpty() {
        let alert = VoiceFailureAlert(reason: .unknown(""), message: nil)
        #expect(alert.title == "Something went wrong")
        #expect(alert.message == "An unexpected error occurred.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("raw caller detail cannot replace safe copy for an unknown failure")
    func unknownCallerMessageCannotReplaceSafeCopy() {
        let alert = VoiceFailureAlert(
            reason: .unknown(""),
            message: "Server error (INTERNAL_ERROR): provider internals"
        )

        #expect(alert.message == "An unexpected error occurred.")
    }

    // MARK: - Caller override

    @Test("caller-supplied transport detail cannot replace safe body copy")
    func messageOverrideIsIgnored() {
        let alert = VoiceFailureAlert(reason: .connect, message: "Custom override")
        #expect(alert.title == "Couldn't connect")
        #expect(alert.message == "The voice service couldn't be reached. Try again in a moment.")
        #expect(alert.primaryAction == .retry)
    }

    @Test("caller transport detail cannot replace microphone copy")
    func messageOverrideCannotReplaceMicCopy() {
        let alert = VoiceFailureAlert(reason: .micDenied, message: "Override")
        #expect(alert.message == "Allow microphone access in Settings to talk with the AI.")
        #expect(alert.primaryAction == .openSettings)
    }

    @Test("sessionEndFailed → dismiss-only affordance + confirm-end copy")
    func sessionEndFailed() {
        let alert = VoiceFailureAlert(reason: .sessionEndFailed, message: nil)
        #expect(alert.title == "Couldn't confirm end")
        #expect(
            alert.message
                == "Voice chat closed on this device, but we couldn't confirm it with the server. It should clear on its own shortly."
        )
        #expect(alert.primaryAction == .dismiss)
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

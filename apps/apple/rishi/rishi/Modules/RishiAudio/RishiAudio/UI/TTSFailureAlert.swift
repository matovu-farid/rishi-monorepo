import SwiftUI

/// Native error surface for Read Aloud. Replaces the inline red status text that
/// used to be the only place `TTSPlaybackState.error` was shown. Modeled on
/// `VoiceFailureAlert`: a pure title/message mapping plus a single "Dismiss"
/// action that clears the error so the bar can keep its compact, status-free
/// layout.
///
/// The static helpers (`message(for:)`, `clear(_:)`) are kept pure so the
/// dismiss/clear behavior is unit-testable without introspecting a SwiftUI body.
public enum TTSFailureAlert {

    public static let title = "Read Aloud error"

    public static let defaultMessage = "Something went wrong while reading aloud."

    /// User-facing message for the alert: the engine-supplied `state.error`
    /// when present, otherwise the generic fallback copy.
    @MainActor
    public static func message(for state: TTSPlaybackState) -> String {
        if let error = state.error, !error.isEmpty { return error }
        return defaultMessage
    }

    /// Clears the error condition so the alert dismisses and the controls leave
    /// the `.error` state. Moving to `.stopped` (not `.idle`) keeps the bar in a
    /// "session ended" posture rather than implying nothing ever started.
    @MainActor
    public static func clear(_ state: TTSPlaybackState) {
        guard state.typedFailure == nil else { return }
        state.error = nil
        if state.status == .error {
            state.update(status: .stopped)
        }
    }
}

public extension View {
    /// Presents a native `.alert` whenever `state.status == .error`, showing
    /// `state.error` (or a fallback) with a single "Dismiss" button that clears
    /// the error. Apply on the reader content so errors surface even when the
    /// control bar is hidden.
    func ttsErrorAlert(state: TTSPlaybackState) -> some View {
        modifier(TTSFailureAlertModifier(state: state))
    }
}

@MainActor
private struct TTSFailureAlertModifier: ViewModifier {
    @Bindable var state: TTSPlaybackState

    func body(content: Content) -> some View {
        content.alert(
            TTSFailureAlert.title,
            isPresented: Binding(
                get: { state.status == .error && state.typedFailure == nil },
                set: { presented in
                    if presented == false { TTSFailureAlert.clear(state) }
                }
            )
        ) {
            Button("Dismiss", role: .cancel) {
                TTSFailureAlert.clear(state)
            }
        } message: {
            Text(TTSFailureAlert.message(for: state))
        }
    }
}

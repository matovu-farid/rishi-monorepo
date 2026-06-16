import SwiftUI
import RishiUIKit

/// Full-screen call UI for an active voice session.
///
/// Binds to the ``VoiceSessionState`` produced by ``RealtimeVoiceSession``
/// (Plan 10-03) and renders:
///   * a status badge at the top,
///   * a large waveform orb whose tint reflects the current lifecycle phase,
///   * the live partial assistant + user transcripts,
///   * a destructive End button that invokes the injected ``onEnd`` closure.
///
/// **VOICE-08**: this surface NEVER routes through CallKit and presents no
/// system call UI. The End button is plain SwiftUI.
public struct VoiceSessionView: View {

    /// Accessibility identifier for the optional "open text chat" control.
    ///
    /// `nonisolated` because a pure-data `String` constant needs no MainActor
    /// isolation and the test suite (default isolation `nonisolated`) reads it
    /// without an `await`. Mirrors the precedent set by
    /// `EPUBReaderScreen.toolbarAccessibilityIdentifiers` in RishiReader.
    nonisolated public static let openTextChatAccessibilityIdentifier = "voice.openTextChat"

    @Bindable private var state: VoiceSessionState
    private let onEnd: () -> Void
    private let onOpenTextChat: (() -> Void)?

    public init(
        state: VoiceSessionState,
        onEnd: @escaping () -> Void,
        onOpenTextChat: (() -> Void)? = nil
    ) {
        self._state = Bindable(wrappedValue: state)
        self.onEnd = onEnd
        self.onOpenTextChat = onOpenTextChat
    }

    public var body: some View {
        VStack(spacing: RishiSpacing.l) {
            VoiceStatusBadge(status: state.status)
                .padding(.top, RishiSpacing.l)

            Spacer(minLength: 0)

            // Visual orb. Static SF Symbol for now — a future plan can swap
            // in an animated waveform without changing the surface.
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .foregroundStyle(orbColor)
                .accessibilityHidden(true)

            // Live transcript area. Auto-scrolling not required at this stage
            // — both partial buffers are short-lived strings that get cleared
            // on the next `clearTranscript(role:)`.
            VStack(alignment: .leading, spacing: RishiSpacing.s) {
                if !state.partialAssistantTranscript.isEmpty {
                    Text(state.partialAssistantTranscript)
                        .font(RishiTypography.body)
                        .foregroundStyle(RishiColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Assistant: \(state.partialAssistantTranscript)")
                }
                if !state.partialUserTranscript.isEmpty {
                    Text(state.partialUserTranscript)
                        .font(RishiTypography.caption)
                        .foregroundStyle(RishiColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("You: \(state.partialUserTranscript)")
                }
            }
            .padding(.horizontal, RishiSpacing.l)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .top)

            Spacer(minLength: 0)

            // End button. NEVER routes through CallKit — see VOICE-08.
            Button(role: .destructive) {
                onEnd()
            } label: {
                Label("End", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.danger)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("voice.end")
            .accessibilityLabel("End voice session")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RishiColor.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            openTextChatButton
        }
    }

    /// Secondary affordance to switch from the (primary) voice surface into
    /// text chat. The app layer presents the actual chat UI (which lives in
    /// RishiChat and must not be imported here). Renders nothing when no hook
    /// is supplied, so there is no orphan control.
    @ViewBuilder
    private var openTextChatButton: some View {
        if let onOpenTextChat {
            Button {
                onOpenTextChat()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.accent)
                    .padding(RishiSpacing.s)
            }
            .padding(.top, RishiSpacing.l)
            .padding(.trailing, RishiSpacing.l)
            .accessibilityIdentifier(Self.openTextChatAccessibilityIdentifier)
            .accessibilityLabel("Open text chat")
        }
    }

    private var orbColor: Color {
        switch state.status {
        case .live:
            return RishiColor.accent
        case .connecting, .fetchingKey, .requestingMic, .reconnecting:
            return RishiColor.textSecondary
        case .failed:
            return RishiColor.danger
        case .idle, .ending, .ended:
            return RishiColor.divider
        }
    }
}

#Preview("Live with transcript") {
    VoiceSessionView(state: {
        let s = VoiceSessionState()
        s.apply(status: .live)
        s.appendTranscript(role: .assistant, content: "Hello — what are we reading today?")
        s.appendTranscript(role: .user, content: "Tell me about chapter three.")
        return s
    }(), onEnd: {})
}

#Preview("Connecting") {
    VoiceSessionView(state: {
        let s = VoiceSessionState()
        s.apply(status: .connecting)
        return s
    }(), onEnd: {})
}

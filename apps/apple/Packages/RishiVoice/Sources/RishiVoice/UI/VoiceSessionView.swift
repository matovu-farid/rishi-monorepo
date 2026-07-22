import SwiftUI
import RishiUIKit

/// Legacy full-screen call UI for an active voice session.
///
/// Production reader chrome uses ``VoiceControlsView`` in a draggable pill
/// overlay (`ReaderAudioChromeOverlay`). This view remains for previews and
/// construction smoke tests.
public struct VoiceSessionView: View {

    /// Accessibility identifier for the optional "open text chat" control.
    ///
    /// `nonisolated` because a pure-data `String` constant needs no MainActor
    /// isolation and the test suite (default isolation `nonisolated`) reads it
    /// without an `await`. Mirrors the precedent set by
    /// `ReaderScreen.toolbarAccessibilityIdentifiers` in RishiReader.
    nonisolated public static let openTextChatAccessibilityIdentifier = "voice.openTextChat"

    /// Native-aspect-ratio slot for the voice character (height 160, width from
    /// ``VoiceCharacterView/canvasAspectRatio`` — 138×179 composition).
    static let characterSlotSize = CGSize(
        width: 160 * VoiceCharacterView.canvasAspectRatio,
        height: 160
    )

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

            if let allowanceLabel {
                Text(allowanceLabel)
                    .font(RishiTypography.caption)
                    .foregroundStyle(
                        state.isFinalInterval ? RishiColor.danger : RishiColor.textSecondary
                    )
                    .accessibilityLabel(allowanceLabel)
            }

            Spacer(minLength: 0)

            // Visual orb. Static SF Symbol for now — a future plan can swap
            // in an animated waveform without changing the surface.
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: Self.characterSlotSize.width, height: Self.characterSlotSize.height)
                .foregroundStyle(orbColor)
                .accessibilityHidden(true)

            // Live transcript area. Finals stay visible until the bridge
            // clears that role on the next non-empty partial (new utterance).
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
        case .connecting, .fetchingKey, .creatingSession, .registeringCall, .requestingMic, .reconnecting:
            return RishiColor.textSecondary
        case .failed:
            return RishiColor.danger
        case .idle, .ending, .ended:
            return RishiColor.divider
        }
    }

    /// Prefers the active allowance pool: trial credits while that pool is
    /// still the binding one, otherwise Voice Chat seconds — never packs
    /// seconds into a "credits" label.
    private var allowanceLabel: String? {
        let prefix = state.isFinalInterval ? "Ending soon · " : ""
        if let credits = state.remainingTrialCredits,
           credits > 0 || state.remainingVoiceChatSeconds == nil {
            return "\(prefix)\(credits) trial credits left"
        }
        if let seconds = state.remainingVoiceChatSeconds {
            return "\(prefix)\(Self.formatVoiceChatSeconds(seconds)) Voice Chat left"
        }
        if let credits = state.remainingTrialCredits {
            return "\(prefix)\(credits) trial credits left"
        }
        if state.isFinalInterval {
            return "Ending soon"
        }
        return nil
    }

    private static func formatVoiceChatSeconds(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let rem = clamped % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
        }
        if minutes > 0 {
            return rem == 0 ? "\(minutes)m" : "\(minutes)m \(rem)s"
        }
        return "\(rem)s"
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

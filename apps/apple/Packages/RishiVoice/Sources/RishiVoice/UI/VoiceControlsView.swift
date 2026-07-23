import SwiftUI
import RishiUIKit

/// Compact pill controls for an active voice session in the reader chrome.
@MainActor
public struct VoiceControlsView: View {

    nonisolated public static let openReadAloudAccessibilityIdentifier = "voice-open-read-aloud"
    nonisolated public static let endAccessibilityIdentifier = "voice-end"
    nonisolated public static let openTextChatAccessibilityIdentifier = "voice.openTextChat"

    @Bindable private var state: VoiceSessionState
    @State private var buttonHapticTick = 0

    private let onEnd: () -> Void
    private let onOpenReadAloud: () -> Void
    private let onOpenTextChat: (() -> Void)?

    public init(
        state: VoiceSessionState,
        onEnd: @escaping () -> Void,
        onOpenReadAloud: @escaping () -> Void,
        onOpenTextChat: (() -> Void)? = nil
    ) {
        self._state = Bindable(wrappedValue: state)
        self.onEnd = onEnd
        self.onOpenReadAloud = onOpenReadAloud
        self.onOpenTextChat = onOpenTextChat
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.s) {
            Spacer(minLength: 0)

            Button(action: performButtonAction(onOpenReadAloud)) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.accent)
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier(Self.openReadAloudAccessibilityIdentifier)
            .accessibilityLabel("Read Aloud")

            centerCluster

            Button(action: performButtonAction(onEnd)) {
                Image(systemName: "phone.down.fill")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.danger)
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier(Self.endAccessibilityIdentifier)
            .accessibilityLabel("End voice session")

            if let onOpenTextChat {
                Button(action: performButtonAction(onOpenTextChat)) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.accent)
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier(Self.openTextChatAccessibilityIdentifier)
                .accessibilityLabel("Open text chat")
            }

            Spacer(minLength: 0)
        }
        .padding(RishiSpacing.l)
        .sensoryFeedback(.impact(weight: .light), trigger: buttonHapticTick)
        .accessibilityElement(children: .contain)
    }

    private var centerCluster: some View {
        VStack(spacing: RishiSpacing.xs) {
            VoiceWaveformView(phase: displayPhase)
                .frame(width: 56, height: 40)

            Text(statusLabel)
                .font(RishiTypography.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .accessibilityLabel("Voice session status: \(statusLabel)")
        }
        .frame(minWidth: 88)
    }

    private var displayPhase: VoiceActivityPhase {
        if case .reconnecting = state.status {
            return .reconnecting
        }
        if case .failed = state.status {
            return .connecting
        }
        if isConnectingStatus {
            return .connecting
        }
        return state.activityPhase
    }

    private var isConnectingStatus: Bool {
        switch state.status {
        case .idle, .requestingMic, .fetchingKey, .creatingSession, .connecting, .registeringCall:
            return true
        default:
            return false
        }
    }

    private var statusLabel: String {
        if case .failed = state.status {
            return state.lastError ?? "Couldn't connect"
        }
        if state.isFinalInterval {
            return "Ending soon"
        }
        switch displayPhase {
        case .connecting:
            return "Connecting…"
        case .listening:
            return "Listening…"
        case .speaking:
            return "Speaking…"
        case .reconnecting:
            return "Reconnecting…"
        }
    }

    private var statusColor: Color {
        state.isFinalInterval ? RishiColor.danger : RishiColor.textSecondary
    }

    private func performButtonAction(_ action: @escaping () -> Void) -> () -> Void {
        {
            buttonHapticTick &+= 1
            action()
        }
    }
}

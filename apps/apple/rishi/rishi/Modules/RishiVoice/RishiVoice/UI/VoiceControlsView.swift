import AVFoundation
import SwiftUI


/// Compact pill controls for an active voice session in the reader chrome.
@MainActor
public struct VoiceControlsView: View {

    nonisolated public static let openReadAloudAccessibilityIdentifier = "voice-open-read-aloud"
    nonisolated public static let endAccessibilityIdentifier = "voice-end"
    nonisolated public static let openTextChatAccessibilityIdentifier = "voice.openTextChat"
    nonisolated public static let iconButtonSize: CGFloat = 48
    private static let connectionCueResourceName = "voice-chat-started"

    @Bindable private var state: VoiceSessionState
    @State private var buttonHapticTick = 0
    @State private var transientStatus: String?
    @State private var transientStatusGeneration = 0
    @State private var hasPlayedLiveConfirmation = false
    @State private var connectionCuePlayer: AVAudioPlayer?

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
        controlsRow
            .overlay(alignment: .top) {
                if let statusText = persistentStatus ?? transientStatus {
                    Text(statusText)
                        .font(RishiTypography.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .padding(.horizontal, RishiSpacing.m)
                        .padding(.vertical, RishiSpacing.xs)
                        .background(.thinMaterial, in: Capsule())
                        .accessibilityLabel("Voice session status: \(statusText)")
                        .accessibilityAddTraits(.updatesFrequently)
                        .transition(.opacity)
                        .offset(y: -RishiSpacing.xl)
                }
            }
            .padding(RishiSpacing.l)
            .sensoryFeedback(.impact(weight: .light), trigger: buttonHapticTick)
            .accessibilityElement(children: .contain)
            .onAppear {
                updateStatusPresentation()
            }
            .onChange(of: state.status) { oldStatus, newStatus in
                updateStatusPresentation()
                handleStatusTransition(from: oldStatus, to: newStatus)
            }
            .onChange(of: state.activityPhase) { _, _ in
                updateStatusPresentation()
            }
            .onChange(of: state.isFinalInterval) { _, _ in
                updateStatusPresentation()
            }
            .task(id: transientStatusGeneration) {
                let generation = transientStatusGeneration
                guard transientStatus != nil else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, transientStatusGeneration == generation else { return }
                withAnimation {
                    transientStatus = nil
                }
            }
    }

    private var controlsRow: some View {
        HStack(spacing: RishiSpacing.m) {
            leadingControls
            centerVisual
            trailingControls
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, RishiSpacing.xl)
    }

    private var leadingControls: some View {
        iconButton(
            systemName: "speaker.wave.2.fill",
            foregroundStyle: RishiColor.accent,
            accessibilityIdentifier: Self.openReadAloudAccessibilityIdentifier,
            accessibilityLabel: "Read Aloud",
            action: onOpenReadAloud
        )
    }

    private var trailingControls: some View {
        HStack(spacing: RishiSpacing.s) {
            iconButton(
                systemName: "phone.down.fill",
                foregroundStyle: RishiColor.danger,
                accessibilityIdentifier: Self.endAccessibilityIdentifier,
                accessibilityLabel: "End voice session",
                action: onEnd
            )

            if let onOpenTextChat {
                iconButton(
                    systemName: "bubble.left.and.bubble.right",
                    foregroundStyle: RishiColor.accent,
                    accessibilityIdentifier: Self.openTextChatAccessibilityIdentifier,
                    accessibilityLabel: "Open text chat",
                    action: onOpenTextChat
                )
            }
        }
    }

    @ViewBuilder
    private var centerVisual: some View {
        if Self.usesProgressVisual(for: state.status) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 56, height: 40)
                .accessibilityHidden(true)
        } else {
            waveform
        }
    }

    private var waveform: some View {
        VoiceWaveformView(phase: displayPhase)
            .frame(width: 56, height: 40)
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
        Self.usesProgressVisual(for: state.status)
    }

    static func usesProgressVisual(for status: VoiceSessionStatus) -> Bool {
        switch status {
        case .idle, .requestingMic, .fetchingKey, .creatingSession, .connecting, .registeringCall:
            return true
        default:
            return false
        }
    }

    static func shouldPlayLiveConfirmation(
        from oldStatus: VoiceSessionStatus?,
        to newStatus: VoiceSessionStatus,
        hasPlayed: Bool
    ) -> Bool {
        guard !hasPlayed, newStatus == .live else { return false }
        guard let oldStatus else { return false }
        switch oldStatus {
        case .reconnecting, .live:
            return false
        default:
            return true
        }
    }

    private var persistentStatus: String? {
        if case .failed = state.status {
            return state.lastError ?? "Couldn't connect"
        }
        if state.isFinalInterval {
            return "Ending soon"
        }
        return nil
    }

    private var transientStatusLabel: String? {
        guard persistentStatus == nil else { return nil }
        switch state.status {
        case .idle, .requestingMic, .fetchingKey, .creatingSession, .connecting, .registeringCall:
            return "Connecting…"
        case .live:
            switch displayPhase {
            case .connecting: return "Connecting…"
            case .listening: return "Listening…"
            case .speaking: return "Speaking…"
            case .reconnecting: return "Reconnecting…"
            }
        case .reconnecting:
            return "Reconnecting…"
        case .ending, .ended, .failed:
            return nil
        }
    }

    private var statusColor: Color {
        state.isFinalInterval || state.status.isFailure ? RishiColor.danger : RishiColor.textSecondary
    }

    private func iconButton(
        systemName: String,
        foregroundStyle: Color,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: performButtonAction(action)) {
            Image(systemName: systemName)
                .font(RishiTypography.titleM)
                .foregroundStyle(foregroundStyle)
                .frame(width: Self.iconButtonSize, height: Self.iconButtonSize)
                .contentShape(Rectangle())
        }
        .frame(width: Self.iconButtonSize, height: Self.iconButtonSize)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }

    private func updateStatusPresentation() {
        transientStatusGeneration &+= 1
        transientStatus = transientStatusLabel
    }

    private func handleStatusTransition(
        from oldStatus: VoiceSessionStatus?,
        to newStatus: VoiceSessionStatus
    ) {
        if newStatus == .idle {
            hasPlayedLiveConfirmation = false
            return
        }

        guard Self.shouldPlayLiveConfirmation(
            from: oldStatus,
            to: newStatus,
            hasPlayed: hasPlayedLiveConfirmation
        ) else { return }

        hasPlayedLiveConfirmation = true
        playConnectionCue()
    }

    private func playConnectionCue() {
        guard let url = AppResourceBundle.bundle.url(
            forResource: Self.connectionCueResourceName,
            withExtension: "mp3"
        ) else {
            Log.event("voice.connection_cue.missing", level: .warning)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.65
            player.prepareToPlay()
            connectionCuePlayer = player
            player.play()
        } catch {
            Log.event(
                "voice.connection_cue.failed",
                level: .warning,
                data: ["error": String(describing: error)]
            )
        }
    }

    private func performButtonAction(_ action: @escaping () -> Void) -> () -> Void {
        {
            buttonHapticTick &+= 1
            action()
        }
    }
}

private extension VoiceSessionStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

import SwiftUI


/// Bottom-sheet style controls for Read Aloud. Bound to the @Observable
/// `TTSPlaybackState`; the host (rishi app layer) presents this as a sheet
/// when the user taps "Read Aloud" in the reader toolbar (plan 08-06).
///
/// All visuals use `RishiUIKit` tokens exclusively (zero hex, zero
/// `.system(size:)`, zero numeric padding literals).
@MainActor
public struct ReadAloudControlsView: View {

    @Bindable var state: TTSPlaybackState
    @State private var buttonHapticTick = 0
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onOpenVoiceChat: () -> Void
    let onOpenPicker: () -> Void
    let onPreviousParagraph: () -> Void
    let onNextParagraph: () -> Void
    let onRepeatParagraph: () -> Void

    public init(
        state: TTSPlaybackState,
        onPlayPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenVoiceChat: @escaping () -> Void = {},
        onOpenPicker: @escaping () -> Void,
        onPreviousParagraph: @escaping () -> Void = {},
        onNextParagraph: @escaping () -> Void = {},
        onRepeatParagraph: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onPlayPause = onPlayPause
        self.onStop = onStop
        self.onOpenVoiceChat = onOpenVoiceChat
        self.onOpenPicker = onOpenPicker
        self.onPreviousParagraph = onPreviousParagraph
        self.onNextParagraph = onNextParagraph
        self.onRepeatParagraph = onRepeatParagraph
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.s) {
            // Centered transport cluster; the play/pause button is the larger
            // central anchor. Reading order: prev · repeat · play/pause · stop ·
            // next. Spacers either side keep the cluster centered while the
            // settings button sits at the trailing edge.
            Spacer(minLength: 0)

            Button(action: performButtonAction(onOpenVoiceChat)) {
                Image(systemName: "waveform.circle.fill")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.accent)
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier("tts-open-voice-chat")
            .accessibilityLabel("Voice Chat")

            transportCluster

            //

            Button(action: performButtonAction(onOpenPicker)) {
                Image(systemName: "gear")
                    .font(RishiTypography.bodyEmphasized)
                    .foregroundStyle(RishiColor.accent)
                    .frame(width: 40, height: 40)
            }
            .accessibilityIdentifier("tts-open-picker")
            .accessibilityLabel("Voice and Speed")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.vertical, RishiSpacing.s)
        .sensoryFeedback(.impact(weight: .light), trigger: buttonHapticTick)
        // No opaque fill here: the host (RootView) supplies the card surface —
        // an iOS 26 Liquid Glass effect, or `.regularMaterial` on iOS 18 — so
        // the panel reads as a translucent floating control over the page.
    }

    @ViewBuilder
    private var transportCluster: some View {
        let cluster = HStack(spacing: RishiSpacing.s) {
            secondaryButton(
                systemName: "backward.end.fill",
                id: "tts-prev-paragraph",
                label: "Previous paragraph",
                action: onPreviousParagraph,
                disabled: navigationDisabled
            )

            secondaryButton(
                systemName: "repeat",
                id: "tts-repeat-paragraph",
                label: "Repeat paragraph",
                action: onRepeatParagraph,
                disabled: navigationDisabled
            )

            playPauseButton

            secondaryButton(
                systemName: "stop.fill",
                id: "tts-stop",
                label: "Stop",
                action: onStop,
                disabled: state.status == .idle || state.status == .stopped
            )

            secondaryButton(
                systemName: "forward.end.fill",
                id: "tts-next-paragraph",
                label: "Next paragraph",
                action: onNextParagraph,
                disabled: navigationDisabled
            )
        }

        // iOS 26 blends/morphs the prominent play/pause glass against the
        // surrounding glyphs when they share a container. iOS 18 just renders
        // the plain HStack.
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { cluster }
        } else {
            cluster
        }
    }

    @ViewBuilder
    private var playPauseButton: some View {
        Button(action: performButtonAction(onPlayPause)) {
            playPauseBody
                .frame(width: 52, height: 52)
        }
        .accessibilityIdentifier(isPlaying ? "tts-pause" : "tts-play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .disabled(state.status == .loading)
        .modifier(PrimaryGlassButtonStyle())
    }
    
    var currentIcon: String {
        switch state.status {
        case .playing, .stopped:
            "pause.fill"
        case .paused:
            "play.fill"
        case .loading:
            "progress.indicator"
        case .error:
            "exclamationmark.triangle"
        case .idle:
            "play.fill"
            
        }
    }
    

    @ViewBuilder
    private var playPauseBody: some View {
        
        if state.status == .loading {
            // Loading keeps the `tts-play` identifier (set above) and stays
            // disabled; only the visual swaps to a spinner. XCUITests rely on
            // this exact toggle.
            ProgressView()
        } else {
            Image(systemName: currentIcon)
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.accent)
        }
    }

    @ViewBuilder
    private func secondaryButton(
        systemName: String,
        id: String,
        label: String,
        action: @escaping () -> Void,
        disabled: Bool
    ) -> some View {
        Button(action: performButtonAction(action)) {
            Image(systemName: systemName)
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textSecondary)
                .frame(width: 42, height: 42)
        }
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
        .disabled(disabled)
    }

    private var isPlaying: Bool { state.status == .playing }

    /// Paragraph navigation only applies while a session is active.
    private var navigationDisabled: Bool {
        state.status == .idle || state.status == .stopped
    }

    private func performButtonAction(_ action: @escaping () -> Void) -> () -> Void {
        {
            buttonHapticTick &+= 1
            action()
        }
    }
}

/// Prominent native Liquid Glass treatment for the central play/pause button on
/// iOS 26; iOS 18 keeps the plain accent glyph the button body already renders.
/// Kept separate so the gating lives in one place and secondary buttons stay
/// plain glyphs over the card glass (no glass-on-glass nesting).
private struct PrimaryGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

#Preview("Playing") {
    let state = TTSPlaybackState()
    state.update(status: .playing)
    return ReadAloudControlsView(
        state: state,
        onPlayPause: {},
        onStop: {},
        onOpenPicker: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

#Preview("Paused") {
    let state = TTSPlaybackState()

    state.update(status: .paused)
    return ReadAloudControlsView(
        state: state,
        onPlayPause: {},
        onStop: {},
        onOpenPicker: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

#Preview("Loading") {
    let state = TTSPlaybackState()
//    state.update(status: .loading)
    state.update(status: .loading)
    return ReadAloudControlsView(
        state: state,
        onPlayPause: {},
        onStop: {},
        onOpenPicker: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

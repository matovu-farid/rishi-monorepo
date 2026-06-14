import SwiftUI
import RishiUIKit

/// Bottom-sheet style controls for Read Aloud. Bound to the @Observable
/// `TTSPlaybackState`; the host (rishi app layer) presents this as a sheet
/// when the user taps "Read Aloud" in the reader toolbar (plan 08-06).
///
/// All visuals use `RishiUIKit` tokens exclusively (zero hex, zero
/// `.system(size:)`, zero numeric padding literals).
@MainActor
public struct ReadAloudControlsView: View {

    @Bindable var state: TTSPlaybackState
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onOpenPicker: () -> Void
    let onPreviousParagraph: () -> Void
    let onNextParagraph: () -> Void
    let onRepeatParagraph: () -> Void

    public init(
        state: TTSPlaybackState,
        onPlayPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenPicker: @escaping () -> Void,
        onPreviousParagraph: @escaping () -> Void = {},
        onNextParagraph: @escaping () -> Void = {},
        onRepeatParagraph: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onPlayPause = onPlayPause
        self.onStop = onStop
        self.onOpenPicker = onOpenPicker
        self.onPreviousParagraph = onPreviousParagraph
        self.onNextParagraph = onNextParagraph
        self.onRepeatParagraph = onRepeatParagraph
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.m) {
            statusLabel

            HStack(spacing: RishiSpacing.s) {
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier(isPlaying ? "tts-pause" : "tts-play")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .disabled(state.status == .loading)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("tts-stop")
                .accessibilityLabel("Stop")
                .disabled(state.status == .idle || state.status == .stopped)

                Button(action: onPreviousParagraph) {
                    Image(systemName: "backward.end.fill")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("tts-prev-paragraph")
                .accessibilityLabel("Previous paragraph")
                .disabled(navigationDisabled)

                Button(action: onRepeatParagraph) {
                    Image(systemName: "repeat")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("tts-repeat-paragraph")
                .accessibilityLabel("Repeat paragraph")
                .disabled(navigationDisabled)

                Button(action: onNextParagraph) {
                    Image(systemName: "forward.end.fill")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("tts-next-paragraph")
                .accessibilityLabel("Next paragraph")
                .disabled(navigationDisabled)

                Spacer()

                Button(action: onOpenPicker) {
                    Image(systemName: "slider.horizontal.3")
                        .font(RishiTypography.titleM)
                        .foregroundStyle(RishiColor.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("tts-open-picker")
                .accessibilityLabel("Voice and Speed")
            }
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated)
    }

    private var isPlaying: Bool { state.status == .playing }

    /// Paragraph navigation only applies while a session is active.
    private var navigationDisabled: Bool {
        state.status == .idle || state.status == .stopped
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.status {
        case .idle, .stopped:
            Text("Ready")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        case .loading:
            Text("Loading…")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        case .playing:
            Text("Playing")
                .font(RishiTypography.bodyEmphasized)
                .foregroundStyle(RishiColor.textPrimary)
        case .paused:
            Text("Paused")
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textSecondary)
        case .error:
            Text(state.error ?? "Error")
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.danger)
        }
    }
}

#Preview("Playing") {
    let state = TTSPlaybackState()
    state.status = .playing
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
    state.status = .paused
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
    state.status = .loading
    return ReadAloudControlsView(
        state: state,
        onPlayPause: {},
        onStop: {},
        onOpenPicker: {}
    )
    .padding(RishiSpacing.l)
    .background(RishiColor.surface)
}

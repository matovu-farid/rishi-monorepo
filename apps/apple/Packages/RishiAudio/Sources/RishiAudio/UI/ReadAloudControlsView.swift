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

    public init(
        state: TTSPlaybackState,
        onPlayPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenPicker: @escaping () -> Void
    ) {
        self.state = state
        self.onPlayPause = onPlayPause
        self.onStop = onStop
        self.onOpenPicker = onOpenPicker
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.m) {
            statusLabel

            HStack(spacing: RishiSpacing.l) {
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

                Spacer()

                Button(action: onOpenPicker) {
                    HStack(spacing: RishiSpacing.xs) {
                        Image(systemName: "slider.horizontal.3")
                            .font(RishiTypography.body)
                        Text("Voice & Speed")
                            .font(RishiTypography.body)
                    }
                    .foregroundStyle(RishiColor.accent)
                    .padding(.horizontal, RishiSpacing.s)
                    .padding(.vertical, RishiSpacing.xs)
                }
                .accessibilityIdentifier("tts-open-picker")
                .accessibilityLabel("Voice and Speed")
            }
        }
        .padding(RishiSpacing.l)
        .background(RishiColor.surfaceElevated)
    }

    private var isPlaying: Bool { state.status == .playing }

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

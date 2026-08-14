


import SwiftUI

enum ReaderAudioChromeMode: Equatable {
    case tts
    case voice
}

struct ReaderAudioChromeOverlay: View {
    let isVisible: Bool
    let mode: ReaderAudioChromeMode
    let ttsState: TTSPlaybackState
    let voiceState: VoiceSessionState
    let readAloud: ReadAloudController?
    let onOpenVoiceChat: () -> Void
    let onOpenReadAloud: () -> Void
    let onEndVoice: () -> Void
    let onOpenTextChat: (() -> Void)?

    @State private var location: CGPoint?
    @State private var controlSize: CGSize = .zero
    @State private var dragHapticTick = 0
    @GestureState private var dragTranslationY: CGFloat = 0
    @GestureState private var isDragging = false

    #if targetEnvironment(macCatalyst)
        private static let macMaxWidth: CGFloat = 520
    #endif

    var body: some View {
        if isVisible {
            GeometryReader { proxy in
                let containerSize = proxy.size

                player
                    .transaction { transaction in
                        if isDragging {
                            transaction.animation = nil
                        }
                    }
                    .simultaneousGesture(dragGesture(in: containerSize))
                    .position(
                        x: containerSize.width / 2,
                        y: committedLocation(in: containerSize).y
                    )
                    .offset(y: dragTranslationY)
                    .frame(
                        width: containerSize.width,
                        height: containerSize.height
                    )
                    .sensoryFeedback(.selection, trigger: dragHapticTick)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: isVisible)
            .animation(.easeInOut(duration: 0.25), value: mode)
        }
    }

    @ViewBuilder
    private var player: some View {
        Group {
            switch mode {
            case .tts:
                if let readAloud {
                    ReadAloudControlsView(
                        state: ttsState,
                        onPlayPause: {
                            Task { await readAloud.togglePlayback() }
                        },
                        onStop: {
                            Task { await readAloud.stop() }
                        },
                        onOpenVoiceChat: onOpenVoiceChat,
                        onOpenPicker: {
                            readAloud.showPicker = true
                        },
                        onPreviousParagraph: {
                            Task { await readAloud.previous() }
                        },
                        onNextParagraph: {
                            Task { await readAloud.next() }
                        },
                        onRepeatParagraph: {
                            Task { await readAloud.repeatCurrent() }
                        }
                    )
                }
            case .voice:
                VoiceControlsView(
                    state: voiceState,
                    onEnd: onEndVoice,
                    onOpenReadAloud: onOpenReadAloud,
                    onOpenTextChat: onOpenTextChat
                )
            }
        }
        .contentTransition(.interpolate)
        #if targetEnvironment(macCatalyst)
            .frame(maxWidth: Self.macMaxWidth)
        #endif
        .modifier(GlassCardBackground(cornerRadius: RishiRadius.pill))
        .shadow(radius: isDragging ? 0 : RishiSpacing.s)
        .padding(.horizontal, RishiSpacing.m)
        .padding(.bottom, RishiSpacing.s)
        .contentShape(
            RoundedRectangle(cornerRadius: RishiRadius.pill, style: .continuous)
        )
        .readChromeSize { size in
            controlSize = size
        }
    }

    private func dragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .updating($dragTranslationY) { value, state, _ in
                state = value.translation.height
            }
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onEnded { value in
                let base = committedLocation(in: containerSize)
                let finalLocation = CGPoint(
                    x: containerSize.width / 2,
                    y: clampedVerticalLocation(
                        base.y + value.translation.height,
                        in: containerSize
                    )
                )
                let didMove = abs(value.translation.height) > 8
                location = finalLocation
                if didMove {
                    dragHapticTick &+= 1
                }
            }
    }

    private func committedLocation(in containerSize: CGSize) -> CGPoint {
        location ?? defaultLocation(in: containerSize)
    }

    private func defaultLocation(in containerSize: CGSize) -> CGPoint {
        let height =
            controlSize.height > 0
            ? controlSize.height : fallbackControlHeight

        return CGPoint(
            x: containerSize.width / 2,
            y: max(
                height / 2 + RishiSpacing.s,
                containerSize.height - height / 2 - RishiSpacing.s
            )
        )
    }

    private func clampedVerticalLocation(
        _ proposedY: CGFloat,
        in containerSize: CGSize
    ) -> CGFloat {
        let height =
            controlSize.height > 0
            ? controlSize.height : fallbackControlHeight
        guard containerSize != .zero else { return proposedY }

        let minY = height / 2 + RishiSpacing.s
        let maxY = max(minY, containerSize.height - height / 2 - RishiSpacing.s)

        return min(max(proposedY, minY), maxY)
    }

    private var fallbackControlHeight: CGFloat {
        96
    }
}

private struct ReaderAudioChromeOverlaySizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    fileprivate func readChromeSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReaderAudioChromeOverlaySizeKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(
            ReaderAudioChromeOverlaySizeKey.self,
            perform: onChange
        )
    }
}

/// Pure visibility helper for tests — mirrors ``ReaderDestination`` overlay gate.
enum ReaderAudioChromeVisibility {
    nonisolated static func shouldShow(voiceActive: Bool, ttsVisible: Bool) -> Bool {
        voiceActive || ttsVisible
    }
}

import RishiAudio
import RishiUIKit
import SwiftUI

struct ReadAloudControlsOverlay: View {
    let controller: ReadAloudController
    let ttsState: TTSPlaybackState
    let onOpenVoiceChat: () -> Void

    @State private var location: CGPoint?
    @State private var controlSize: CGSize = .zero
    @State private var dragHapticTick = 0
    @GestureState private var dragTranslationY: CGFloat = 0
    @GestureState private var isDragging = false

    #if targetEnvironment(macCatalyst)

        private static let macMaxWidth: CGFloat = 520
    #endif

    var body: some View {
        if controller.showControls {
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
                    .onDisappear { location = nil }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(
                .easeInOut(duration: 0.25),
                value: controller.showControls
            )
        }
    }

    private var player: some View {
        ReadAloudControlsView(
            state: ttsState,
            onPlayPause: {
                Task { await controller.togglePlayback() }
            },
            onStop: {
                Task { await controller.stop() }
            },
            onOpenVoiceChat: onOpenVoiceChat,
            onOpenPicker: {
                controller.showPicker = true
            },
            onPreviousParagraph: {
                Task { await controller.previous() }
            },
            onNextParagraph: {
                Task { await controller.next() }
            },
            onRepeatParagraph: {
                Task { await controller.repeatCurrent() }
            }
        )
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
        .readSize { controlSize = $0 }
    }

    private func resolvedLocation(in containerSize: CGSize) -> CGPoint {
        committedLocation(in: containerSize)
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
        let container = containerSize
        let measuredSize = controlSize
        let height =
            measuredSize.height > 0
            ? measuredSize.height : fallbackControlHeight

        return CGPoint(
            x: container.width / 2,
            y: max(
                height / 2 + RishiSpacing.s,
                container.height - height / 2 - RishiSpacing.s
            )
        )
    }

    private func clampedVerticalLocation(
        _ proposedY: CGFloat,
        in containerSize: CGSize
    ) -> CGFloat {
        let measuredSize = controlSize
        let height =
            measuredSize.height > 0
            ? measuredSize.height : fallbackControlHeight
        guard containerSize != .zero else { return proposedY }

        let minY = height / 2 + RishiSpacing.s
        let maxY = max(minY, containerSize.height - height / 2 - RishiSpacing.s)

        return min(max(proposedY, minY), maxY)
    }

    private var fallbackControlHeight: CGFloat {
        96
    }
}

private struct ReadAloudControlsOverlaySizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    fileprivate func readSize(onChange: @escaping (CGSize) -> Void) -> some View
    {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReadAloudControlsOverlaySizeKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(
            ReadAloudControlsOverlaySizeKey.self,
            perform: onChange
        )
    }
}

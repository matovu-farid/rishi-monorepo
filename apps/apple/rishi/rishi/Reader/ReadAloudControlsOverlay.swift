








import SwiftUI
import RishiAudio
import RishiUIKit

struct ReadAloudControlsOverlay: View {
    let controller: ReadAloudController
    let ttsState: TTSPlaybackState

    @State private var location: CGPoint?
    @State private var controlSize: CGSize = .zero

    #if targetEnvironment(macCatalyst)
    
    
    private static let macMaxWidth: CGFloat = 520
    #endif

    var body: some View {
        if controller.showControls {
            GeometryReader { proxy in
                let containerSize = proxy.size

                ZStack(alignment: .topLeading) {
                    dragBackdrop(in: containerSize)

                    player
                        .simultaneousGesture(dragGesture(in: containerSize))
                        .position(resolvedLocation(in: containerSize))
                }
                .frame(width: containerSize.width, height: containerSize.height)
                .onDisappear { location = nil }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: controller.showControls)
        }
    }

    private var player: some View {
        ReadAloudControlsView(
            state: ttsState,
            onPlayPause: {
                guard let bridge = controller.bridge else { return }
                Task {
                    if ttsState.status == .playing {
                        await bridge.pause()
                    } else {
                        await bridge.resume()
                    }
                }
            },
            onStop: {
                Task { await controller.stop() }
            },
            onOpenPicker: {
                controller.showPicker = true
            },
            onPreviousParagraph: {
                guard let bridge = controller.bridge else { return }
                Task { await bridge.previous() }
            },
            onNextParagraph: {
                guard let bridge = controller.bridge else { return }
                Task { await bridge.next() }
            },
            onRepeatParagraph: {
                guard let bridge = controller.bridge else { return }
                Task { await bridge.repeatCurrent() }
            }
        )
        #if targetEnvironment(macCatalyst)
        .frame(maxWidth: Self.macMaxWidth)
        #endif
        .modifier(GlassCardBackground(cornerRadius: RishiRadius.pill))
        .shadow(radius: RishiSpacing.s)
        .padding(.horizontal, RishiSpacing.m)
        .padding(.bottom, RishiSpacing.s)
        .readSize { controlSize = $0 }
    }

    private func resolvedLocation(in containerSize: CGSize) -> CGPoint {
        let center = location ?? defaultLocation(in: containerSize)
        return CGPoint(
            x: containerSize.width / 2,
            y: clampedVerticalLocation(center.y, in: containerSize)
        )
    }

    private func dragBackdrop(in containerSize: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture(in: containerSize))
    }

    private func dragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                location = CGPoint(
                    x: containerSize.width / 2,
                    y: clampedVerticalLocation(value.location.y, in: containerSize)
                )
            }
            .onEnded { value in
                location = CGPoint(
                    x: containerSize.width / 2,
                    y: clampedVerticalLocation(value.location.y, in: containerSize)
                )
            }
    }

    private func defaultLocation(in containerSize: CGSize) -> CGPoint {
        let container = containerSize
        let measuredSize = controlSize
        let height = measuredSize.height > 0 ? measuredSize.height : fallbackControlHeight

        return CGPoint(
            x: container.width / 2,
            y: max(height / 2 + RishiSpacing.s, container.height - height / 2 - RishiSpacing.s)
        )
    }

    private func clampedVerticalLocation(_ proposedY: CGFloat, in containerSize: CGSize) -> CGFloat {
        let measuredSize = controlSize
        let height = measuredSize.height > 0 ? measuredSize.height : fallbackControlHeight
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

private extension View {
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReadAloudControlsOverlaySizeKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(ReadAloudControlsOverlaySizeKey.self, perform: onChange)
    }
}

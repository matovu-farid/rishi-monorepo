//
//  ReadAloudControlsOverlay.swift
//  rishi
//
//  Phase 29 refactor — promotes the read-aloud controls overlay into its own
//  View struct so each reader destination can embed it without capturing
//  SignedInView state.
//

import SwiftUI
import RishiAudio
import RishiUIKit

struct ReadAloudControlsOverlay: View {
    let controller: ReadAloudController
    let ttsState: TTSPlaybackState

    var body: some View {
        if controller.showControls, let bridge = controller.bridge {
            ReadAloudControlsView(
                state: ttsState,
                onPlayPause: {
                    // KEEP: UI play/pause action hops to the MainActor-isolated TTS bridge
                    Task {
                        if ttsState.status == .playing {
                            await bridge.pause()
                        } else {
                            await bridge.resume()
                        }
                    }
                },
                onStop: {
                    // KEEP: UI stop action hops to the MainActor-isolated TTS controller
                    Task { await controller.stop() }
                },
                onOpenPicker: {
                    controller.showPicker = true
                },
                onPreviousParagraph: {
                    // KEEP: UI previous-paragraph action hops to the MainActor-isolated TTS bridge
                    Task { await bridge.previous() }
                },
                onNextParagraph: {
                    // KEEP: UI next-paragraph action hops to the MainActor-isolated TTS bridge
                    Task { await bridge.next() }
                },
                onRepeatParagraph: {
                    // KEEP: UI repeat-paragraph action hops to the MainActor-isolated TTS bridge
                    Task { await bridge.repeatCurrent() }
                }
            )
            .modifier(GlassCardBackground(cornerRadius: RishiRadius.large))
            .shadow(radius: RishiSpacing.s)
            .padding(.horizontal, RishiSpacing.m)
            .padding(.bottom, RishiSpacing.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: controller.showControls)
        }
    }
}

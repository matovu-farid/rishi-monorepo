








import SwiftUI
import RishiAudio
import RishiUIKit

struct ReadAloudControlsOverlay: View {
    let controller: ReadAloudController
    let ttsState: TTSPlaybackState

    #if targetEnvironment(macCatalyst)
    
    
    private static let macMaxWidth: CGFloat = 520
    #endif

    var body: some View {
        if controller.showControls, let bridge = controller.bridge {
            ReadAloudControlsView(
                state: ttsState,
                onPlayPause: {
                    
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
                    
                    Task { await bridge.previous() }
                },
                onNextParagraph: {
                    
                    Task { await bridge.next() }
                },
                onRepeatParagraph: {
                    
                    Task { await bridge.repeatCurrent() }
                }
            )
            #if targetEnvironment(macCatalyst)
            
            
            
            
            .frame(maxWidth: Self.macMaxWidth)
            #endif
            .modifier(GlassCardBackground(cornerRadius: RishiRadius.large))
            .shadow(radius: RishiSpacing.s)
            .padding(.horizontal, RishiSpacing.m)
            .padding(.bottom, RishiSpacing.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: controller.showControls)
        }
    }
}

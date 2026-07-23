import SwiftUI

/// The system-owned output picker for AirPlay, Bluetooth, and other audio
/// routes. Keeping this as an MPVolumeView wrapper lets iOS decide which
/// destinations and iconography to show; the app never maintains a parallel
/// device list.
struct SystemAudioRoutePicker: View {
    var body: some View {
        #if canImport(UIKit) && canImport(MediaPlayer)
            SystemAudioRoutePickerRepresentable()
                .frame(height: 32)
                .accessibilityIdentifier("tts-audio-route-picker")
                .accessibilityLabel("Audio Output")
        #else
            EmptyView()
        #endif
    }
}

enum SystemAudioRoutePickerVisibility {
    nonisolated static func shouldShow(ttsActive: Bool) -> Bool {
        ttsActive
    }
}

#if canImport(UIKit) && canImport(MediaPlayer)
import MediaPlayer
import UIKit

private struct SystemAudioRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        // Keep the route button visible even when the system updates the
        // available output routes while the reader remains on screen.
        view.showsVolumeSlider = false
        view.showsRouteButton = true
    }
}
#endif

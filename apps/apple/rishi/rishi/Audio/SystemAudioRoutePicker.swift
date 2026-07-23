import SwiftUI

/// The system-owned output picker for AirPlay, Bluetooth, and other audio
/// routes. Keeping this as an MPVolumeView wrapper lets iOS decide which
/// destinations and iconography to show; the app never maintains a parallel
/// device list.
struct SystemAudioRoutePicker: View {
    var body: some View {
        #if canImport(UIKit) && canImport(AVKit)
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

#if canImport(UIKit) && canImport(AVKit)
import AVKit
import UIKit

private struct SystemAudioRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        // Keep the system-owned route picker available as routes change.
        view.backgroundColor = .clear
    }
}
#endif

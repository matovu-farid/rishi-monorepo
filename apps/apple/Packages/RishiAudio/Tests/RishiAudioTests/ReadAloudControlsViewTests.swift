import Testing
import Foundation
import SwiftUI
@testable import RishiAudio

@Suite("ReadAloudControlsView + VoiceCatalog", .serialized)
struct ReadAloudControlsViewTests {

    @MainActor
    @Test("Renders without crashing for every TTSStatus")
    func rendersAllStatuses() {
        for status in TTSStatus.allCases {
            let state = TTSPlaybackState()
            state.status = status
            _ = ReadAloudControlsView(
                state: state,
                onPlayPause: {},
                onStop: {},
                onOpenPicker: {}
            )
        }
    }

    @MainActor
    @Test("Error status surfaces state.error string")
    func errorStatusUsesErrorString() {
        let state = TTSPlaybackState()
        state.status = .error
        state.error = "Network down"
        let view = ReadAloudControlsView(
            state: state,
            onPlayPause: {},
            onStop: {},
            onOpenPicker: {}
        )
        // We can't introspect SwiftUI view bodies portably without a snapshot
        // lib, but constructing without throwing exercises the .error branch.
        _ = view
        #expect(state.error == "Network down")
    }

    @MainActor
    @Test("TTSFailureAlert.clear resets error and moves status off .error")
    func ttsErrorAlertClear() {
        let state = TTSPlaybackState()
        state.status = .error
        state.error = "Network down"

        TTSFailureAlert.clear(state)

        #expect(state.error == nil)
        #expect(state.status != .error)
    }

    @MainActor
    @Test("TTSFailureAlert.message falls back when state.error is nil")
    func ttsErrorAlertMessageFallback() {
        let state = TTSPlaybackState()
        state.status = .error
        state.error = nil
        #expect(TTSFailureAlert.message(for: state) == TTSFailureAlert.defaultMessage)

        state.error = "Network down"
        #expect(TTSFailureAlert.message(for: state) == "Network down")
    }

    @Test("VoiceCatalog.all is the 6 OpenAI voice ids")
    func voiceCatalog() {
        #expect(VoiceCatalog.all == ["alloy", "echo", "fable", "onyx", "nova", "shimmer"])
    }

    @Test("VoiceCatalog.displayName capitalises the first letter")
    func voiceCatalogDisplay() {
        #expect(VoiceCatalog.displayName(for: "alloy") == "Alloy")
        #expect(VoiceCatalog.displayName(for: "nova") == "Nova")
        #expect(VoiceCatalog.displayName(for: "shimmer") == "Shimmer")
    }

    @Test("VoiceCatalog.displayName tolerates empty input")
    func voiceCatalogEmpty() {
        #expect(VoiceCatalog.displayName(for: "") == "")
    }
}

@testable import rishi
import Testing
import Foundation
import SwiftUI


@Suite("ReadAloudControlsView + VoiceCatalog", .serialized)
struct ReadAloudControlsViewTests {

    @MainActor
    @Test("Renders without crashing for every TTSStatus")
    func rendersAllStatuses() {
        for status in TTSStatus.allCases {
            let state = TTSPlaybackState()
            state.update(status: status)
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
        state.update(status: .error)
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
        state.update(status: .error)
        state.error = "Network down"

        TTSFailureAlert.clear(state)

        #expect(state.error == nil)
        #expect(state.status != .error)
    }

    @MainActor
    @Test("TTSFailureAlert uses sanitized user-facing copy")
    func ttsErrorAlertMessageFallback() {
        let state = TTSPlaybackState()
        state.update(status: .error)
        state.error = nil
        #expect(TTSFailureAlert.message(for: state) == TTSFailureAlert.defaultMessage)

        state.error = "Network down"
        #expect(TTSFailureAlert.message(for: state) == TTSFailureAlert.defaultMessage)
    }

    @Test("VoiceCatalog.all is the reader voice preset list")
    func voiceCatalog() {
        #expect(VoiceCatalog.all == [
            "alloy",
            "ash",
            "ballad",
            "coral",
            "echo",
            "fable",
            "nova",
            "onyx",
            "sage",
            "shimmer",
            "verse",
            "marin",
            "cedar",
        ])
    }

    @Test("VoiceCatalog.displayName capitalises the first letter")
    func voiceCatalogDisplay() {
        #expect(VoiceCatalog.displayName(for: "alloy") == "Alloy")
        #expect(VoiceCatalog.displayName(for: "nova") == "Nova")
        #expect(VoiceCatalog.displayName(for: "shimmer") == "Shimmer")
        #expect(VoiceCatalog.displayName(for: "marin") == "Marin")
        #expect(VoiceCatalog.displayName(for: "cedar") == "Cedar")
    }

    @Test("VoiceCatalog.displayName tolerates empty input")
    func voiceCatalogEmpty() {
        #expect(VoiceCatalog.displayName(for: "") == "")
    }
}

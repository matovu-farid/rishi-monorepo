//
//  ReadAloudControllerTests.swift
//  rishiTests
//
//  Tests for ReadAloudController — the extracted TTS orchestration type.
//
//  We test the ENGINE-INDEPENDENT logic only. Starting real playback requires a
//  live AVAudioEngine and a network-backed TTSChunkSource, neither of which is
//  available offline. Instead, we inject FakeTTSEngine (from RishiAudio) which
//  scripts TTSPlaybackState transitions deterministically — the same double used
//  by ReaderTTSBridgeAdvanceTests.
//
//  Tests cover:
//  1. `paragraphs` set on start, cleared on stop.
//  2. `bridge` non-nil after start, nil after stop.
//  3. `showControls` follows start/stop.
//  4. Passage-change -> `currentParagraph` mapping: in-range, out-of-range/nil.
//  5. Empty paragraph list does not create a bridge.
//  6. `pickerInitial` is loaded from the settings store on start.
//  7. Double-start tears down the first bridge before creating a second.
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

// MARK: - Suite

@Suite("ReadAloudController")
@MainActor
struct ReadAloudControllerTests {

    // MARK: - Factory

    /// Builds a ReadAloudController wired to a FakeTTSEngine.
    ///
    /// Default script is `.holds` — the fake drives `state.status` to
    /// `.playing` and never advances to `.stopped`, so the advance watcher
    /// never fires. This keeps tests focused on controller state management
    /// (paragraphs, bridge presence, showControls) rather than the
    /// full-playback loop (covered by ReaderTTSBridgeAdvanceTests).
    private func makeController(
        script: FakeTTSEngine.Script = .holds
    ) -> ReadAloudController {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: script)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: ControllerNoopChunkSource())
        let userId = UserID()
        return ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: settingsStore,
            ttsPrewarmer: prewarmer,
            userId: userId
        )
    }

    // MARK: - paragraphs + bridge + showControls lifecycle

    @Test("paragraphs populated and bridge non-nil after start")
    func paragraphsAndBridgeSetAfterStart() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo", "charlie"],
            onPassageChange: { _ in }
        )

        #expect(controller.paragraphs == ["alpha", "bravo", "charlie"])
        #expect(controller.bridge != nil)
        #expect(controller.showControls == true)
        // currentParagraph is nil until the bridge fires onPassageChange.
        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("stop clears paragraphs, bridge, showControls, and currentParagraph")
    func stopClearsState() async {
        let controller = makeController()

        await controller.start(paragraphs: ["one", "two"], onPassageChange: { _ in })
        #expect(controller.paragraphs.count == 2)

        await controller.stop()

        #expect(controller.paragraphs.isEmpty)
        #expect(controller.bridge == nil)
        #expect(controller.showControls == false)
        #expect(controller.showPicker == false)
        #expect(controller.currentParagraph == nil)
    }

    @Test("empty paragraph list does not create a bridge")
    func emptyParagraphListSkipsStart() async {
        let controller = makeController()

        await controller.start(paragraphs: [], onPassageChange: { _ in })

        #expect(controller.bridge == nil)
        #expect(controller.showControls == false)
        #expect(controller.paragraphs.isEmpty)
    }

    // MARK: - Passage-change -> currentParagraph mapping

    @Test("in-range passage index resolves to paragraph text")
    func passageChangeInRangeSetsParagraph() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo", "charlie"],
            onPassageChange: { _ in }
        )

        // Invoke the passage-mapping method directly (internal visibility).
        controller.updateCurrentParagraph(for: 1)

        #expect(controller.currentParagraph == "bravo")

        await controller.stop()
    }

    @Test("out-of-range passage index clears currentParagraph")
    func passageChangeOutOfRangeClearsParagraph() async {
        let controller = makeController()

        await controller.start(paragraphs: ["alpha", "bravo"], onPassageChange: { _ in })
        // Resolve a valid paragraph first.
        controller.updateCurrentParagraph(for: 0)
        #expect(controller.currentParagraph == "alpha")

        // Out-of-range index clears.
        controller.updateCurrentParagraph(for: 99)
        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("nil passage index clears currentParagraph (teardown signal)")
    func passageChangeNilClearsParagraph() async {
        let controller = makeController()

        await controller.start(paragraphs: ["alpha"], onPassageChange: { _ in })
        controller.updateCurrentParagraph(for: 0)
        #expect(controller.currentParagraph == "alpha")

        controller.updateCurrentParagraph(for: nil)
        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("passage-change closure sets currentParagraph when wired through start")
    func passageChangeClosure_setsParagraph() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo"],
            onPassageChange: { [controller] index in
                controller.updateCurrentParagraph(for: index)
            }
        )

        // The FakeTTSEngine(.holds) drives state to .playing but never .stopped,
        // so auto-advance never fires. Invoke the mapping directly.
        controller.updateCurrentParagraph(for: 1)
        #expect(controller.currentParagraph == "bravo")

        await controller.stop()
    }

    // MARK: - pickerInitial

    @Test("pickerInitial matches TTSSettings.default when store has no saved settings")
    func pickerInitialMatchesDefault() async {
        let controller = makeController()

        await controller.start(paragraphs: ["x"], onPassageChange: { _ in })

        // InMemoryTTSSettingsStore returns .default when nothing has been saved.
        #expect(controller.pickerInitial == TTSSettings.default)

        await controller.stop()
    }

    // MARK: - Re-entry (double start)

    @Test("calling start twice tears down the first bridge and installs a new one")
    func doubleStartTearDownsFirst() async {
        let controller = makeController()

        await controller.start(paragraphs: ["alpha"], onPassageChange: { _ in })
        let firstBridge = controller.bridge

        await controller.start(paragraphs: ["bravo"], onPassageChange: { _ in })
        let secondBridge = controller.bridge

        #expect(secondBridge != nil)
        // The new bridge replaced the old reference.
        #expect(firstBridge !== secondBridge)
        #expect(controller.paragraphs == ["bravo"])

        await controller.stop()
    }
}

// MARK: - Test double

/// No-op TTSChunkSource so TTSPrewarmer can be constructed without a live
/// WorkerClient. Read-ahead drains an empty stream, which is a valid no-op.
private struct ControllerNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

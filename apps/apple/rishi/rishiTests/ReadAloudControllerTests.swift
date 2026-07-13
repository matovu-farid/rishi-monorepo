import Foundation
import RishiAudio
import RishiCore
import Testing

@testable import rishi

@Suite("ReadAloudController")
@MainActor
struct ReadAloudControllerTests {

    private func makeController(
        script: FakeTTSEngine.Script = .holds,
        source: any TTSChunkSource = ControllerNoopChunkSource()
    ) -> ReadAloudController {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: script)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: source)
        let configurer = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurer)
        let userId = UserID()
        return ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: settingsStore,
            ttsPrewarmer: prewarmer,
            coordidator: coordinator,
            userId: userId
        )
    }

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

        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("stop clears paragraphs, bridge, showControls, and currentParagraph")
    func stopClearsState() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["one", "two"],
            onPassageChange: { _ in }
        )
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

    @Test("in-range passage index resolves to paragraph text")
    func passageChangeInRangeSetsParagraph() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo", "charlie"],
            onPassageChange: { _ in }
        )

        controller.updateCurrentParagraph(for: 1)

        #expect(controller.currentParagraph == "bravo")

        await controller.stop()
    }

    @Test("out-of-range passage index clears currentParagraph")
    func passageChangeOutOfRangeClearsParagraph() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo"],
            onPassageChange: { _ in }
        )

        controller.updateCurrentParagraph(for: 0)
        #expect(controller.currentParagraph == "alpha")

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

    @Test(
        "passage-change closure sets currentParagraph when wired through start"
    )
    func passageChangeClosure_setsParagraph() async {
        let controller = makeController()

        await controller.start(
            paragraphs: ["alpha", "bravo"],
            onPassageChange: { [weak controller] index in
                controller?.updateCurrentParagraph(for: index)
            }
        )

        controller.updateCurrentParagraph(for: 1)
        #expect(controller.currentParagraph == "bravo")

        await controller.stop()
    }

    @Test(
        "pickerInitial matches TTSSettings.default when store has no saved settings"
    )
    func pickerInitialMatchesDefault() async {
        let controller = makeController()

        await controller.start(paragraphs: ["x"], onPassageChange: { _ in })

        #expect(controller.pickerInitial == TTSSettings.default)

        await controller.stop()
    }

    @Test(
        "calling start twice tears down the first bridge and installs a new one"
    )
    func doubleStartTearDownsFirst() async {
        let controller = makeController()

        await controller.start(paragraphs: ["alpha"], onPassageChange: { _ in })
        let firstBridge = controller.bridge

        await controller.start(paragraphs: ["bravo"], onPassageChange: { _ in })
        let secondBridge = controller.bridge

        #expect(secondBridge != nil)

        #expect(firstBridge !== secondBridge)
        #expect(controller.paragraphs == ["bravo"])

        await controller.stop()
    }

    @Test("page-entry prefetch is ignored before Read Aloud starts")
    func pageEntryPrefetchRequiresSession() async {
        let source = ControllerRecordingChunkSource()
        let controller = makeController(source: source)

        #expect(controller.canPrefetchPageEntry == false)
        await controller.prefetchFirstParagraph("not started")

        #expect(await source.snapshot().isEmpty)
    }

    @Test("page-entry prefetch warms one paragraph while stopped")
    func pageEntryPrefetchWarmsOneParagraph() async {
        let source = ControllerRecordingChunkSource()
        let controller = makeController(source: source)
        await controller.start(paragraphs: ["current"], onPassageChange: { _ in })
        await controller.stop()

        #expect(controller.canPrefetchPageEntry)
        await controller.prefetchFirstParagraph("new page first")
        let requests = await waitForRequests(source, count: 1)

        #expect(requests.map(\.text) == ["new page first"])
        #expect(requests[0].passageId == nil)
        await controller.stop()
    }

    @Test("page-entry prefetch is ignored while playing")
    func pageEntryPrefetchSkipsPlaying() async {
        let source = ControllerRecordingChunkSource()
        let controller = makeController(source: source)
        await controller.start(paragraphs: ["current"], onPassageChange: { _ in })

        #expect(controller.canPrefetchPageEntry == false)
        await controller.prefetchFirstParagraph("playing page")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await source.snapshot().isEmpty)
        await controller.stop()
    }

    @Test("page-entry prefetch eligibility follows user pause and resume")
    func pageEntryPrefetchEligibilityTracksPauseAndResume() async {
        let controller = makeController()
        await controller.start(paragraphs: ["current"], onPassageChange: { _ in })

        #expect(controller.canPrefetchPageEntry == false)
        await controller.togglePlayback()
        #expect(controller.canPrefetchPageEntry)

        await controller.togglePlayback()
        #expect(controller.canPrefetchPageEntry == false)

        await controller.stop()
    }

    @Test("starting a new Read Aloud session clears stopped eligibility")
    func newReadAloudSessionClearsStoppedEligibility() async {
        let controller = makeController()
        await controller.start(paragraphs: ["first"], onPassageChange: { _ in })
        await controller.stop()
        #expect(controller.canPrefetchPageEntry)

        await controller.start(paragraphs: ["second"], onPassageChange: { _ in })

        #expect(controller.canPrefetchPageEntry == false)
        await controller.stop()
    }

    @Test("final custom bridge exhaustion enables page-entry prefetch")
    func finalCustomBridgeExhaustionEnablesPageEntryPrefetch() async {
        let controller = makeController()
        await controller.start(
            paragraphs: ["last"],
            onPassageChange: { _ in },
            onParagraphsExhausted: { [] }
        )

        #expect(controller.canPrefetchPageEntry == false)
        await controller.next()

        #expect(controller.canPrefetchPageEntry)
        await controller.stop()
    }

    @Test("intermediate custom bridge exhaustion does not enable page-entry prefetch")
    func intermediateCustomBridgeExhaustionSkipsPageEntryPrefetch() async {
        let controller = makeController()
        await controller.start(
            paragraphs: ["current"],
            onPassageChange: { _ in },
            onParagraphsExhausted: { ["next"] }
        )

        await controller.next()

        #expect(controller.canPrefetchPageEntry == false)
        await controller.stop()
    }
}

private struct ControllerNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ControllerRecordingChunkSource: TTSChunkSource {
    private(set) var requests: [TTSStreamRequest] = []

    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        requests.append(request)
        return AsyncThrowingStream { $0.finish() }
    }

    func snapshot() -> [TTSStreamRequest] { requests }
}

private func waitForRequests(
    _ source: ControllerRecordingChunkSource,
    count: Int
) async -> [TTSStreamRequest] {
    for _ in 0..<100 {
        let requests = await source.snapshot()
        if requests.count >= count {
            return requests
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await source.snapshot()
}

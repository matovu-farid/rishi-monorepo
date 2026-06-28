import Foundation
import RishiAudio
import RishiCore
import Testing

@testable import rishi

@Suite("ReadAloudController")
@MainActor
struct ReadAloudControllerTests {

    private func makeController(
        script: FakeTTSEngine.Script = .holds
    ) -> ReadAloudController {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: script)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: ControllerNoopChunkSource())
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
}

private struct ControllerNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

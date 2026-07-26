import Foundation


import Testing

@testable import rishi

@Suite("ReadAloudController")
@MainActor
struct ReadAloudControllerTests {

    private let testBookID = "test-book"
    private let testMetadata = NowPlayingMetadata(title: "Test Book")

    private func makeController(
        script: FakeTTSEngine.Script = .holds,
        source: any TTSChunkSource = ControllerNoopChunkSource(),
        nowPlayingController: NowPlayingController? = nil,
        audioSessionConfigurator: FakeAudioSessionConfigurator = FakeAudioSessionConfigurator()
    ) -> ReadAloudController {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: script)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: source)
        let coordinator = AudioSessionCoordinator(configurator: audioSessionConfigurator)
        let presence = rishi.TTSPresenceController(
            state: state,
            store: ControllerNoopPresenceStore()
        )
        let userId = UserID()
        return ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: settingsStore,
            ttsPrewarmer: prewarmer,
            ttsPresence: presence,
            coordidator: coordinator,
            userId: userId,
            nowPlayingController: nowPlayingController
        )
    }

    private func start(
        _ controller: ReadAloudController,
        paragraphs: [String],
        onPassageChange: @escaping (Int?) -> Void = { _ in },
        onParagraphsExhausted: @escaping () async -> [String] = { [] }
    ) async {
        await controller.start(
            paragraphs: paragraphs,
            bookID: testBookID,
            metadata: testMetadata,
            onPassageChange: onPassageChange,
            onParagraphsExhausted: onParagraphsExhausted
        )
    }

    @Test("paragraphs populated and bridge non-nil after start")
    func paragraphsAndBridgeSetAfterStart() async {
        let controller = makeController()

        await start(controller, paragraphs: ["alpha", "bravo", "charlie"])

        #expect(controller.paragraphs == ["alpha", "bravo", "charlie"])
        #expect(controller.bridge != nil)
        #expect(controller.showControls == true)

        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("Readium narration start activates the playback spoken-audio session")
    func readiumNarrationStartActivatesSpokenAudioSession() async {
        let configurator = FakeAudioSessionConfigurator()
        let controller = makeController(audioSessionConfigurator: configurator)

        await controller.activateAudioSessionForReadiumStart()

        #expect(configurator.configureCalls.count == 1)
        #expect(configurator.configureCalls[0].category == .playback)
        #expect(configurator.configureCalls[0].mode == .spokenAudio)
        #expect(configurator.activeCalls.last?.active == true)
    }

    @Test("output route loss pauses an active legacy reader session")
    func routeLossPausesLegacyReader() async {
        let configurator = FakeAudioSessionConfigurator()
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: .holds)
        let controller = ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: ControllerNoopChunkSource()),
            ttsPresence: rishi.TTSPresenceController(
                state: state,
                store: ControllerNoopPresenceStore()
            ),
            coordidator: AudioSessionCoordinator(configurator: configurator),
            userId: UserID()
        )

        await start(controller, paragraphs: ["one"])
        #expect(state.status == .playing)

        configurator.inject(route: .oldDeviceUnavailable)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(engine.calls.contains(.pause))
        #expect(state.status == .paused)
        await controller.stop()
    }

    @Test("stop clears paragraphs, bridge, showControls, and currentParagraph")
    func stopClearsState() async {
        let controller = makeController()

        await start(controller, paragraphs: ["one", "two"])
        #expect(controller.paragraphs.count == 2)

        await controller.stop()

        #expect(controller.paragraphs.isEmpty)
        #expect(controller.bridge == nil)
        #expect(controller.showControls == false)
        #expect(controller.showPicker == false)
        #expect(controller.currentParagraph == nil)
    }

    @Test("legacy session attaches lock-screen controls and stop detaches them")
    func legacySessionAttachesAndDetachesNowPlaying() async {
        let info = FakeNowPlayingInfoSurface()
        let commands = FakeRemoteCommandSurface()
        let nowPlaying = NowPlayingController(infoSurface: info, commandSurface: commands)
        let controller = makeController(nowPlayingController: nowPlaying)

        await start(controller, paragraphs: ["one"])

        #expect(commands.calls == [.register])
        #expect(info.calls.contains(.metadata(testMetadata)))

        await controller.stop()

        #expect(commands.calls == [.register, .unregister])
        #expect(info.calls.contains(.clear))
    }

    @Test("starting narration publishes Now Playing before the session can be stopped")
    func legacyStartPublishesNowPlayingImmediately() async {
        let info = FakeNowPlayingInfoSurface()
        let commands = FakeRemoteCommandSurface()
        let nowPlaying = NowPlayingController(infoSurface: info, commandSurface: commands)
        let controller = makeController(nowPlayingController: nowPlaying)

        await start(controller, paragraphs: ["one"])

        #expect(info.calls.first == .metadata(testMetadata))
        #expect(commands.calls == [.register])
        await controller.stop()
    }

    @Test("lock-screen playback-rate command persists a supported reader speed")
    func lockScreenPlaybackRateUpdatesReaderSettings() async {
        let info = FakeNowPlayingInfoSurface()
        let commands = FakeRemoteCommandSurface()
        let nowPlaying = NowPlayingController(infoSurface: info, commandSurface: commands)
        let controller = makeController(nowPlayingController: nowPlaying)

        await start(controller, paragraphs: ["one"])
        #expect(controller.pickerInitial.speed == TTSSettings.default.speed)

        #expect(commands.simulate(.changePlaybackRate(1.5)) == .success)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.pickerInitial.speed == 1.5)
        await controller.stop()
    }

    @Test("lock-screen playback-rate command rejects unsupported reader speed")
    func lockScreenPlaybackRateRejectsUnsupportedSpeed() async {
        let info = FakeNowPlayingInfoSurface()
        let commands = FakeRemoteCommandSurface()
        let nowPlaying = NowPlayingController(infoSurface: info, commandSurface: commands)
        let controller = makeController(nowPlayingController: nowPlaying)

        await start(controller, paragraphs: ["one"])
        #expect(commands.simulate(.changePlaybackRate(1.1)) == .commandFailed)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.pickerInitial.speed == TTSSettings.default.speed)
        await controller.stop()
    }

    @Test("explicit stop releases the TTS audio session once")
    func explicitStopReleasesTTSAudioSession() async {
        let configurator = FakeAudioSessionConfigurator()
        let state = TTSPlaybackState()
        let controller = ReadAloudController(
            ttsEngine: FakeTTSEngine(state: state, script: .holds),
            ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: ControllerNoopChunkSource()),
            ttsPresence: rishi.TTSPresenceController(
                state: state,
                store: ControllerNoopPresenceStore()
            ),
            coordidator: AudioSessionCoordinator(configurator: configurator),
            userId: UserID()
        )

        await start(controller, paragraphs: ["one"])
        await controller.stop()
        await controller.stop()

        #expect(configurator.activeCalls.map(\.active) == [true, false])
    }

    @Test("lock-screen stop command stops the reader session")
    func lockScreenStopStopsReaderSession() async {
        let info = FakeNowPlayingInfoSurface()
        let commands = FakeRemoteCommandSurface()
        let nowPlaying = NowPlayingController(infoSurface: info, commandSurface: commands)
        let controller = makeController(nowPlayingController: nowPlaying)

        await start(controller, paragraphs: ["one"])
        commands.simulate(.stop)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(controller.bridge == nil)
        #expect(commands.calls == [.register, .unregister])
    }

    @Test("empty paragraph list does not create a bridge")
    func emptyParagraphListSkipsStart() async {
        let controller = makeController()

        await start(controller, paragraphs: [])

        #expect(controller.bridge == nil)
        #expect(controller.showControls == false)
        #expect(controller.paragraphs.isEmpty)
    }

    @Test("in-range passage index resolves to paragraph text")
    func passageChangeInRangeSetsParagraph() async {
        let controller = makeController()

        await start(controller, paragraphs: ["alpha", "bravo", "charlie"])

        controller.updateCurrentParagraph(for: 1)

        #expect(controller.currentParagraph == "bravo")

        await controller.stop()
    }

    @Test("out-of-range passage index clears currentParagraph")
    func passageChangeOutOfRangeClearsParagraph() async {
        let controller = makeController()

        await start(controller, paragraphs: ["alpha", "bravo"])

        controller.updateCurrentParagraph(for: 0)
        #expect(controller.currentParagraph == "alpha")

        controller.updateCurrentParagraph(for: 99)
        #expect(controller.currentParagraph == nil)

        await controller.stop()
    }

    @Test("nil passage index clears currentParagraph (teardown signal)")
    func passageChangeNilClearsParagraph() async {
        let controller = makeController()

        await start(controller, paragraphs: ["alpha"])
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

        await start(
            controller,
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

        await start(controller, paragraphs: ["x"])

        #expect(controller.pickerInitial == TTSSettings.default)

        await controller.stop()
    }

    @Test(
        "calling start twice tears down the first bridge and installs a new one"
    )
    func doubleStartTearDownsFirst() async {
        let controller = makeController()

        await start(controller, paragraphs: ["alpha"])
        let firstBridge = controller.bridge

        await start(controller, paragraphs: ["bravo"])
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
        await start(controller, paragraphs: ["current"])
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
        await start(controller, paragraphs: ["current"])

        #expect(controller.canPrefetchPageEntry == false)
        await controller.prefetchFirstParagraph("playing page")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await source.snapshot().isEmpty)
        await controller.stop()
    }

    @Test("page-entry prefetch eligibility follows user pause and resume")
    func pageEntryPrefetchEligibilityTracksPauseAndResume() async {
        let controller = makeController()
        await start(controller, paragraphs: ["current"])

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
        await start(controller, paragraphs: ["first"])
        await controller.stop()
        #expect(controller.canPrefetchPageEntry)

        await start(controller, paragraphs: ["second"])

        #expect(controller.canPrefetchPageEntry == false)
        await controller.stop()
    }

    @Test("final custom bridge exhaustion enables page-entry prefetch")
    func finalCustomBridgeExhaustionEnablesPageEntryPrefetch() async {
        let controller = makeController()
        await start(
            controller,
            paragraphs: ["last"],
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
        await start(
            controller,
            paragraphs: ["current"],
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

private final class ControllerNoopPresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
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

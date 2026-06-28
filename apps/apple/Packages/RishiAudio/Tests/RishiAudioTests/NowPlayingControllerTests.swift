import Testing
import Foundation
@testable import RishiAudio

@Suite("NowPlayingController", .serialized)
struct NowPlayingControllerTests {

    /// Test controller — actor that records every method invocation.
    actor RecordingController: TTSPlaybackControlling {
        enum Call: Sendable, Equatable {
            case pause, resume, stop
            case skip(TimeInterval)
            case scrub(TimeInterval)
        }
        private(set) var calls: [Call] = []
        func pause() async { calls.append(.pause) }
        func resume() async { calls.append(.resume) }
        func stop() async { calls.append(.stop) }
        func skip(seconds: TimeInterval) async { calls.append(.skip(seconds)) }
        func scrub(toSeconds seconds: TimeInterval) async { calls.append(.scrub(seconds)) }
    }

    @MainActor
    @Test("attach() sets metadata and registers handlers")
    func attachSetsMetadataAndRegisters() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "Alice", author: "Lewis Carroll"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let metadataCalls = info.calls.compactMap { call -> NowPlayingMetadata? in
            if case .metadata(let m) = call { return m } else { return nil }
        }
        #expect(metadataCalls.first?.title == "Alice")
        #expect(metadataCalls.first?.author == "Lewis Carroll")
        #expect(cmd.calls.contains(.register))
        controller.detach()
    }

    @MainActor
    @Test("Pause remote command triggers controller.pause()")
    func pauseCommandTriggersPause() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.pause)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.pause))
        controller.detach()
    }

    @MainActor
    @Test("Play remote command triggers controller.resume()")
    func playCommandTriggersResume() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.play)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.resume))
        controller.detach()
    }

    @MainActor
    @Test("Skip forward fires controller.skip(+seconds)")
    func skipForwardFiresSkip() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.skipForward(seconds: 15))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.skip(15)))
        controller.detach()
    }

    @MainActor
    @Test("Scrub fires controller.scrub(toSeconds:)")
    func scrubFiresScrub() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.scrub(toSeconds: 42))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.scrub(42)))
        controller.detach()
    }

    @MainActor
    @Test("State transition to .playing publishes rate 1.0")
    func playingPublishesRate1() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        state.update(status: .playing)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rates = info.calls.compactMap { call -> Double? in
            if case .rate(let r) = call { return r } else { return nil }
        }
        #expect(rates.contains(1.0))
        controller.detach()
    }

    @MainActor
    @Test("detach() clears info and unregisters")
    func detachClearsAndUnregisters() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        controller.detach()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(info.calls.contains(.clear))
        #expect(cmd.calls.contains(.unregister))
    }
}

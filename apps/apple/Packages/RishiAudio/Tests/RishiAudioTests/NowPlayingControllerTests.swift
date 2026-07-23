import Testing
import Foundation
@testable import RishiAudio

@Suite("NowPlayingController", .serialized)
struct NowPlayingControllerTests {

    /// Test controller — actor that records every method invocation.
    actor RecordingController: TTSPlaybackControlling {
        enum Call: Sendable, Equatable {
            case pause, resume, stop
            case previousTrack, nextTrack
            case changePlaybackRate(Double)
        }
        private(set) var calls: [Call] = []
        func pause() async { calls.append(.pause) }
        func resume() async { calls.append(.resume) }
        func stop() async { calls.append(.stop) }
        func previousTrack() async { calls.append(.previousTrack) }
        func nextTrack() async { calls.append(.nextTrack) }
        func changePlaybackRate(to rate: Double) async { calls.append(.changePlaybackRate(rate)) }
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
    @Test("Previous-track remote command triggers controller.previousTrack()")
    func previousTrackCommandTriggersPrevious() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.previousTrack)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.previousTrack))
        controller.detach()
    }

    @MainActor
    @Test("Next-track remote command triggers controller.nextTrack()")
    func nextTrackCommandTriggersNext() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.nextTrack)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.nextTrack))
        controller.detach()
    }

    @MainActor
    @Test("Stop remote command triggers controller.stop()")
    func stopCommandTriggersStop() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
        cmd.simulate(.stop)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await rec.calls
        #expect(calls.contains(.stop))
        controller.detach()
    }

    @MainActor
    @Test("Supported playback-rate remote command updates the reader speed")
    func supportedPlaybackRateCommandTriggersChange() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(
            state: state,
            controller: rec,
            metadata: .init(title: "x", playbackRate: 1.0, supportedPlaybackRates: [0.75, 1.0, 1.25, 1.5, 2.0])
        )

        let result = cmd.simulate(.changePlaybackRate(1.5))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(result == .success)
        #expect(await rec.calls.contains(.changePlaybackRate(1.5)))
        controller.detach()
    }

    @MainActor
    @Test("Unsupported playback-rate remote command fails without changing reader speed")
    func unsupportedPlaybackRateCommandFails() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(
            state: state,
            controller: rec,
            metadata: .init(title: "x", playbackRate: 1.0, supportedPlaybackRates: [0.75, 1.0, 1.25, 1.5, 2.0])
        )

        let result = cmd.simulate(.changePlaybackRate(1.1))
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(result == .commandFailed)
        #expect(await rec.calls.contains(where: { if case .changePlaybackRate = $0 { return true }; return false }) == false)
        controller.detach()
    }

    @MainActor
    @Test("Playing publishes the selected playback rate")
    func playingPublishesSelectedRate() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        controller.attach(
            state: state,
            controller: rec,
            metadata: .init(title: "x", playbackRate: 1.5, supportedPlaybackRates: [0.75, 1.0, 1.25, 1.5, 2.0])
        )
        state.update(status: .playing)
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(info.calls == [.metadata(.init(title: "x", playbackRate: 1.5, supportedPlaybackRates: [0.75, 1.0, 1.25, 1.5, 2.0])), .rate(1.5)])
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
    @Test("Playing publishes metadata and rate without elapsed progress")
    func playingDoesNotPublishElapsedProgress() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        let metadata = NowPlayingMetadata(title: "x")
        controller.attach(state: state, controller: rec, metadata: metadata)
        state.update(status: .playing)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(info.calls == [.metadata(metadata), .rate(1.0)])
        controller.detach()
    }

    @MainActor
    @Test("Initial idle and stopped states retain metadata and remote handlers")
    func initialTerminalStatesRetainMediaSession() async {
        for initialStatus in [TTSStatus.idle, .stopped] {
            let info = FakeNowPlayingInfoSurface()
            let cmd = FakeRemoteCommandSurface()
            let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
            let state = TTSPlaybackState()
            let rec = RecordingController()
            let metadata = NowPlayingMetadata(title: "x")

            controller.attach(state: state, controller: rec, metadata: metadata)
            state.update(status: initialStatus)
            try? await Task.sleep(nanoseconds: 100_000_000)

            #expect(info.calls == [.metadata(metadata)])
            #expect(cmd.calls == [.register])
            controller.detach()
        }
    }

    @MainActor
    @Test("Paragraph terminal TTS states retain media session after playback becomes active")
    func terminalStatesRetainMediaSessionAfterPlayback() async {
        for status in [TTSStatus.stopped, .idle, .error] {
            let info = FakeNowPlayingInfoSurface()
            let cmd = FakeRemoteCommandSurface()
            let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
            let state = TTSPlaybackState()
            let rec = RecordingController()
            controller.attach(state: state, controller: rec, metadata: .init(title: "x"))
            state.update(status: .playing)
            try? await Task.sleep(nanoseconds: 100_000_000)
            state.update(status: status)
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(cmd.calls == [.register])
            #expect(info.calls == [.metadata(.init(title: "x")), .rate(1.0)])
            controller.detach()
            #expect(cmd.calls == [.register, .unregister])
        }
    }

    @MainActor
    @Test("Repeated attach and detach do not register duplicate handlers")
    func attachAndDetachAreIdempotent() async {
        let info = FakeNowPlayingInfoSurface()
        let cmd = FakeRemoteCommandSurface()
        let controller = NowPlayingController(infoSurface: info, commandSurface: cmd)
        let state = TTSPlaybackState()
        let rec = RecordingController()
        let metadata = NowPlayingMetadata(title: "x")
        controller.attach(state: state, controller: rec, metadata: metadata)
        controller.attach(state: state, controller: rec, metadata: metadata)
        #expect(cmd.calls == [.register])
        controller.detach()
        controller.detach()
        #expect(cmd.calls == [.register, .unregister])
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

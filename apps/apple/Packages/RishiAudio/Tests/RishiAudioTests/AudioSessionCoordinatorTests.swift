import Testing
import Foundation
@testable import RishiAudio

@Suite("AudioSessionCoordinator", .serialized)
struct AudioSessionCoordinatorTests {

    @Test("Starts in .idle")
    func startsIdle() async {
        let coord = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let mode = await coord.currentMode
        #expect(mode == .idle)
    }

    @Test("Requesting .tts configures .playback / .spokenAudio + activates")
    func requestTTSConfiguresPlayback() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        let mode = await coord.currentMode
        #expect(mode == .tts)
        let calls = fake.configureCalls
        #expect(calls.count == 1)
        #expect(calls[0].category == .playback)
        #expect(calls[0].mode == .spokenAudio)
        #expect(calls[0].options.contains(.allowBluetooth))
        #expect(calls[0].options.contains(.allowAirPlay))
        let active = fake.activeCalls.last
        #expect(active?.active == true)
    }

    @Test("Requesting .tts twice is idempotent (no double configure)")
    func requestTTSTwiceIsIdempotent() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.tts)
        #expect(fake.configureCalls.count == 1)
    }

    @Test(".voice after .tts deactivates first then reconfigures")
    func voiceAfterTTSTearsDownFirst() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.voice)
        let mode = await coord.currentMode
        #expect(mode == .voice)
        // Order: configure(.playback), setActive(true), setActive(false),
        // configure(.playAndRecord), setActive(true)
        #expect(fake.configureCalls.count == 2)
        #expect(fake.configureCalls[1].category == .playAndRecord)
        #expect(fake.configureCalls[1].mode == .voiceChat)
        // setActive false appears between configures
        let actives = fake.activeCalls.map(\.active)
        #expect(actives == [true, false, true])
    }

    @Test("releaseActiveMode(.tts) while in .voice is a no-op")
    func releaseWrongModeIsNoOp() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.voice)
        await coord.releaseActiveMode(.tts) // wrong owner
        let mode = await coord.currentMode
        #expect(mode == .voice)
    }

    @Test("Interruption .began suspends but does not change mode")
    func interruptionBeganSuspends() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        fake.inject(.began)
        // Allow the interruption Task to drain
        try? await Task.sleep(nanoseconds: 50_000_000)
        let mode = await coord.currentMode
        let suspended = await coord.isSuspended
        #expect(mode == .tts)
        #expect(suspended == true)
    }

    @Test("Interruption .endedShouldResume re-activates session")
    func interruptionEndedShouldResume() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        fake.inject(.began)
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.inject(.endedShouldResume)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let mode = await coord.currentMode
        let suspended = await coord.isSuspended
        #expect(mode == .tts)
        #expect(suspended == false)
        // setActive(true) appears at least twice: initial request + resume
        let trues = fake.activeCalls.filter { $0.active == true }
        #expect(trues.count >= 2)
    }

    @Test("Interruption .endedNoResume drops to .idle")
    func interruptionEndedNoResumeDropsIdle() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        await coord.requestActiveMode(.tts)
        fake.inject(.endedNoResume)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let mode = await coord.currentMode
        #expect(mode == .idle)
    }
}

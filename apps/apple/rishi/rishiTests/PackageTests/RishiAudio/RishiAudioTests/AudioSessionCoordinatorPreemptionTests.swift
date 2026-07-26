@testable import rishi
import Testing
import Foundation


@Suite("AudioSessionCoordinator preemption", .serialized)
struct AudioSessionCoordinatorPreemptionTests {

    // Sendable counter the preempt closures can mutate across actor hops.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("requesting voice while tts active runs the tts preempt handler once, then goes voice")
    func voicePreemptsTTS() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let ttsStops = Counter()
        await coord.registerPreemption(for: .tts) { ttsStops.bump() }

        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.voice)

        #expect(ttsStops.value == 1)
        #expect(await coord.currentMode == .voice)
    }

    @Test("requesting tts while voice active runs the voice preempt handler once, then goes tts")
    func ttsPreemptsVoice() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let voiceStops = Counter()
        await coord.registerPreemption(for: .voice) { voiceStops.bump() }

        await coord.requestActiveMode(.voice)
        await coord.requestActiveMode(.tts)

        #expect(voiceStops.value == 1)
        #expect(await coord.currentMode == .tts)
    }

    @Test("staying in the same mode does NOT run a preempt handler")
    func samesModeNoPreempt() async {
        let fake = FakeAudioSessionConfigurator()
        let coord = AudioSessionCoordinator(configurator: fake)
        let ttsStops = Counter()
        await coord.registerPreemption(for: .tts) { ttsStops.bump() }

        await coord.requestActiveMode(.tts)
        await coord.requestActiveMode(.tts) // passage switch, not an owner change

        #expect(ttsStops.value == 0)
        #expect(await coord.currentMode == .tts)
    }
}

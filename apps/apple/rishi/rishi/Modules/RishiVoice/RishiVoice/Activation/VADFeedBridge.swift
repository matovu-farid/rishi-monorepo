import AVFoundation
import Foundation

/// Thread-safe fan-out from the activation recorder tap to energy + optional Speech VAD.
final class VADFeedBridge: @unchecked Sendable {

    private let lock = NSLock()
    private weak var energy: EnergyVADMonitor?
    private var speech: SpeechVADMonitoring?

    func attach(energy: EnergyVADMonitor) {
        lock.withLock { self.energy = energy }
    }

    func attachSpeech(_ monitor: SpeechVADMonitoring?) {
        lock.withLock { speech = monitor }
    }

    func process(buffer: AVAudioPCMBuffer) {
        let (energyMonitor, speechMonitor) = lock.withLock {
            (energy, speech)
        }
        energyMonitor?.process(buffer: buffer)
        speechMonitor?.process(buffer: buffer)
    }
}

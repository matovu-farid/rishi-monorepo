import AVFoundation
import Foundation

/// RMS-threshold fallback when Speech recognition is unavailable or denied.
final class EnergyVADMonitor: SpeechVADMonitoring, @unchecked Sendable {

    private let lock = NSLock()
    private let hangoverMs: Int
    private let speechThreshold: Float = 0.028

    private var _everSpoke = false
    private var lastSpeechAt: ContinuousClock.Instant?

    var everSpoke: Bool { lock.withLock { _everSpoke } }
    var accumulatedTranscript: String? { nil }

    init(hangoverMs: Int) {
        self.hangoverMs = hangoverMs
    }

    func start() throws {}

    /// Stops monitoring without clearing `everSpoke` — handoff reads speech state first.
    func stop() {
        lock.withLock {
            lastSpeechAt = nil
        }
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        let channels = Int(buffer.format.channelCount)
        for frame in 0..<frameCount {
            var sample: Float = 0
            for ch in 0..<channels {
                sample += channelData[ch][frame]
            }
            sample /= Float(channels)
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))

        lock.withLock {
            if rms >= speechThreshold {
                _everSpoke = true
                lastSpeechAt = ContinuousClock.now
            }
        }
    }

    func waitForSpeechEnd(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let silent: Bool = lock.withLock {
                guard _everSpoke, let last = lastSpeechAt else { return true }
                return (ContinuousClock.now - last) >= .milliseconds(hangoverMs)
            }
            if silent { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

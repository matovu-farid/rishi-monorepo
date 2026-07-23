import AVFoundation
import Foundation

struct ActivationAudioSnapshot: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

/// Local PCM ring buffer fed by a single `AVAudioEngine` input tap.
final class ActivationAudioRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private let maxBufferSeconds: Int
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    init(maxBufferSeconds: Int) {
        self.maxBufferSeconds = maxBufferSeconds
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
            onBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        lock.withLock { self.engine = engine }
    }

    func stop() {
        lock.withLock {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
        }
    }

    func snapshot() -> ActivationAudioSnapshot {
        lock.withLock {
            ActivationAudioSnapshot(samples: samples, sampleRate: sampleRate)
        }
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        lock.withLock {
            let channels = Int(buffer.format.channelCount)
            samples.reserveCapacity(samples.count + frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += channelData[ch][frame]
                }
                samples.append(sum / Float(channels))
            }

            let maxSamples = Int(sampleRate * Double(maxBufferSeconds))
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }
    }
}

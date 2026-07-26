import AVFoundation
import Foundation

/// Converts device-rate float PCM to OpenAI Realtime inject format:
/// PCM16 little-endian, 24 kHz, mono.
enum PCM24kConverter {

    static let targetSampleRate: Double = 24_000

    /// Convert a single tap buffer to PCM16 LE 24 kHz mono bytes.
    static func convert(buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData else { return Data() }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Data() }

        let inputRate = buffer.format.sampleRate
        var mono = [Float](repeating: 0, count: frameCount)
        let channels = Int(buffer.format.channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channels {
                sum += channelData[ch][frame]
            }
            mono[frame] = sum / Float(channels)
        }
        return convert(samples: mono, sampleRate: inputRate)
    }

    /// Resample mono float samples to PCM16 LE 24 kHz.
    static func convert(samples: [Float], sampleRate: Double) -> Data {
        guard !samples.isEmpty, sampleRate > 0 else { return Data() }

        let resampled: [Float]
        if abs(sampleRate - targetSampleRate) < 1 {
            resampled = samples
        } else {
            let ratio = targetSampleRate / sampleRate
            let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
            resampled = (0..<outCount).map { i in
                let srcIndex = Double(i) / ratio
                let lo = Int(srcIndex)
                let hi = min(lo + 1, samples.count - 1)
                let frac = Float(srcIndex - Double(lo))
                return samples[lo] * (1 - frac) + samples[hi] * frac
            }
        }

        var pcm16 = Data(capacity: resampled.count * 2)
        for sample in resampled {
            let clipped = max(-1, min(1, sample))
            let intSample = Int16(clipped * (clipped < 0 ? 32_768 : 32_767))
            var le = intSample.littleEndian
            withUnsafeBytes(of: &le) { pcm16.append(contentsOf: $0) }
        }
        return pcm16
    }
}

import Foundation
#if canImport(AVFAudio)
import AVFAudio

/// Decoded PCM unit ready for AVAudioPlayerNode.scheduleBuffer.
/// `passageId` carries the TTS-06 link-back; `isFinal` lets the scheduler
/// know to release the audio session after this buffer drains.
///
/// `@unchecked Sendable` because AVAudioPCMBuffer is not Sendable. Ownership
/// is single-consumer: the decoder yields a chunk, the scheduler reads it
/// once, no other code touches the buffer.
public struct PCMChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let passageId: String?
    public let isFinal: Bool

    public init(buffer: AVAudioPCMBuffer, passageId: String?, isFinal: Bool) {
        self.buffer = buffer
        self.passageId = passageId
        self.isFinal = isFinal
    }
}
#endif

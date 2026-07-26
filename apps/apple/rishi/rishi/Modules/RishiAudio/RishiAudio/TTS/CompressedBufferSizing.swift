import Foundation

/// Pure sizing logic for the `AVAudioCompressedBuffer` that
/// `MP3StreamDecoder.flushPendingPackets` allocates before copying packet
/// bytes into it.
///
/// Why this exists as a standalone, testable type:
/// `AVAudioCompressedBuffer(format:packetCapacity:maximumPacketSize:)` allocates
/// `byteCapacity = packetCapacity * maximumPacketSize`, and
/// `setByteLength(_:)` asserts `length <= byteCapacity`. The decoder writes
/// `totalBytes = sum(packet blob sizes)` and then sets `byteLength = totalBytes`.
///
/// The original code derived `maximumPacketSize` from `max(mDataByteSize)` over
/// the packet descriptions. That product (`packetCount * maxPacketSize`) is NOT
/// guaranteed to be `>= totalBytes` — the descriptions and the actual copied
/// bytes can desync (one Data blob per parser callback vs. one description per
/// packet; description sizes need not sum to the bytes actually copied). When
/// `totalBytes` exceeds the product, AVFoundation raises
/// `required condition is false: length <= _imp->_byteCapacity` and the app
/// crashes mid-playback.
///
/// `CompressedBufferSizing.make` guarantees `packetCapacity * maximumPacketSize
/// >= totalBytes` for every input, so `setByteLength(totalBytes)` can never
/// exceed the allocated capacity.
enum CompressedBufferSizing {

    struct Result: Equatable {
        /// Number of packets the buffer can describe. Always >= 1 when there
        /// are bytes to copy.
        let packetCapacity: UInt32
        /// Per-packet capacity used to compute byteCapacity. Chosen so that
        /// packetCapacity * maximumPacketSize >= totalBytes.
        let maximumPacketSize: Int

        /// The capacity AVAudioCompressedBuffer will allocate.
        var byteCapacity: Int { Int(packetCapacity) * maximumPacketSize }
    }

    /// Compute a buffer sizing guaranteed to hold `totalBytes`.
    ///
    /// - Parameters:
    ///   - packetCount: number of packet descriptions to be written
    ///     (`pendingDescriptions.count`).
    ///   - packetSizes: the per-packet `mDataByteSize` values (used to seed a
    ///     sensible `maximumPacketSize`).
    ///   - totalBytes: the actual number of bytes that will be copied into the
    ///     buffer (`sum(pendingPackets blob sizes)`).
    /// - Returns: a `Result` whose `byteCapacity >= totalBytes`, or `nil` when
    ///   there is nothing to allocate (`totalBytes <= 0`).
    static func make(packetCount: Int, packetSizes: [UInt32], totalBytes: Int) -> Result? {
        guard totalBytes > 0 else { return nil }

        // At least one packet slot — even a single description must be writable.
        let capacity = UInt32(max(packetCount, 1))

        // Seed from the largest declared packet size, but never trust it to
        // bound the real byte total. Take the max of:
        //   - the largest declared packet size, and
        //   - ceil(totalBytes / capacity)  (the per-slot size needed to fit
        //     all bytes across `capacity` slots).
        // This makes capacity * maximumPacketSize >= totalBytes by construction.
        let declaredMax = Int(packetSizes.max() ?? 0)
        let perSlotForTotal = (totalBytes + Int(capacity) - 1) / Int(capacity) // ceil division
        let maximumPacketSize = max(declaredMax, perSlotForTotal, 1)

        return Result(packetCapacity: capacity, maximumPacketSize: maximumPacketSize)
    }
}

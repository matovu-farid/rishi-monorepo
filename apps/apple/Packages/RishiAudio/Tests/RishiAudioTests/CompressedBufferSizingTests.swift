import Testing
import Foundation
@testable import RishiAudio

/// Regression coverage for the mid-TTS crash:
///   "required condition is false: length <= _imp->_byteCapacity"
/// raised by AVAudioCompressedBuffer.setByteLength when the decoder's buffer
/// was sized as packetCount*maxPacketSize but loaded with totalBytes that
/// exceeded that product.
@Suite("CompressedBufferSizing")
struct CompressedBufferSizingTests {

    /// The core invariant: byteCapacity must always be >= totalBytes so that
    /// setByteLength(totalBytes) cannot assert.
    @Test("byteCapacity always covers totalBytes")
    func capacityCoversTotalBytes() {
        // Crash repro shape: count*max underflows the real byte total.
        // 3 packets, declared max 100 -> old formula byteCapacity = 300,
        // but the bytes actually copied total 15968 (from the crash log).
        let sizing = CompressedBufferSizing.make(
            packetCount: 3,
            packetSizes: [100, 80, 60],
            totalBytes: 15968
        )
        let result = try! #require(sizing)
        #expect(result.byteCapacity >= 15968)
    }

    /// Demonstrates that the OLD formula (count * max) under-allocates for the
    /// crash inputs — i.e. this is a genuine fix, not a no-op.
    @Test("old count*max formula would under-allocate for crash inputs")
    func oldFormulaUnderAllocates() {
        let packetCount = 3
        let maxSize = 100
        let totalBytes = 15968
        // Old: byteCapacity = count * max = 300 < 15968 -> assertion would fire.
        #expect(packetCount * maxSize < totalBytes)
        // New: helper produces capacity that covers it.
        let result = try! #require(
            CompressedBufferSizing.make(
                packetCount: packetCount,
                packetSizes: [UInt32(maxSize)],
                totalBytes: totalBytes
            )
        )
        #expect(result.byteCapacity >= totalBytes)
    }

    @Test("returns nil when there are no bytes to copy")
    func nilForEmpty() {
        #expect(CompressedBufferSizing.make(packetCount: 0, packetSizes: [], totalBytes: 0) == nil)
        #expect(CompressedBufferSizing.make(packetCount: 5, packetSizes: [10], totalBytes: 0) == nil)
    }

    @Test("packetCapacity is at least 1 even with zero descriptions")
    func atLeastOnePacketSlot() {
        let result = try! #require(
            CompressedBufferSizing.make(packetCount: 0, packetSizes: [], totalBytes: 64)
        )
        #expect(result.packetCapacity >= 1)
        #expect(result.byteCapacity >= 64)
    }

    @Test("normal well-formed input keeps capacity tight but sufficient")
    func wellFormedInput() {
        // 4 packets, each ~417 bytes, total 1668. Declared max 417.
        // count*max = 1668 >= total, so capacity should comfortably cover it.
        let result = try! #require(
            CompressedBufferSizing.make(
                packetCount: 4,
                packetSizes: [417, 417, 417, 417],
                totalBytes: 1668
            )
        )
        #expect(result.byteCapacity >= 1668)
        #expect(result.packetCapacity == 4)
    }

    @Test("fuzz: capacity always covers totalBytes across random inputs")
    func fuzzInvariant() {
        for _ in 0..<2000 {
            let count = Int.random(in: 0...64)
            let sizes = (0..<max(count, 1)).map { _ in UInt32.random(in: 0...1500) }
            // totalBytes deliberately decoupled from sizes to model the desync.
            let totalBytes = Int.random(in: 1...65_536)
            let result = try! #require(
                CompressedBufferSizing.make(packetCount: count, packetSizes: sizes, totalBytes: totalBytes)
            )
            #expect(result.byteCapacity >= totalBytes)
            #expect(result.packetCapacity >= 1)
        }
    }
}

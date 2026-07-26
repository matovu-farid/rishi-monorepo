@testable import rishi
import Testing
import PropertyBased


/// Property-based tests (x-sheep/swift-property-based) for the pure read-aloud
/// start-index mapping. `startIndex(forProgression:count:)` maps a Readium
/// within-resource progression to the paragraph index "Play" should begin at on
/// a forwarded page. These check invariants across randomly generated inputs
/// (with shrinking) rather than a handful of hardcoded cases.
@Suite("ParagraphChunker.startIndex (property-based)")
struct ParagraphChunkerStartIndexPropertyTests {

    @Test("result is always a valid in-range index for a non-empty resource")
    func indexAlwaysInRange() async {
        await propertyCheck(input: Gen.double(in: 0.0 ... 1.0), Gen.int(in: 1 ... 5000)) { progression, count in
            let index = ParagraphChunker.startIndex(forProgression: progression, count: count)
            #expect(index >= 0)
            #expect(index < count)
        }
    }

    @Test("monotonic: a later page never starts before an earlier page")
    func monotonicInProgression() async {
        await propertyCheck(input: Gen.double(in: 0.0 ... 1.0), Gen.double(in: 0.0 ... 1.0), Gen.int(in: 1 ... 5000)) { a, b, count in
            let lo = min(a, b)
            let hi = max(a, b)
            let iLo = ParagraphChunker.startIndex(forProgression: lo, count: count)
            let iHi = ParagraphChunker.startIndex(forProgression: hi, count: count)
            #expect(iLo <= iHi)
        }
    }

    @Test("progression 0 (or nil) starts at paragraph 0 for any count")
    func startOfResourceIsIndexZero() async {
        await propertyCheck(input: Gen.int(in: 0 ... 5000)) { count in
            #expect(ParagraphChunker.startIndex(forProgression: 0, count: count) == 0)
            #expect(ParagraphChunker.startIndex(forProgression: nil, count: count) == 0)
        }
    }

    @Test("empty resource (count 0) is always index 0, never out of range")
    func emptyResourceIsZero() async {
        await propertyCheck(input: Gen.double(in: 0.0 ... 1.0)) { progression in
            #expect(ParagraphChunker.startIndex(forProgression: progression, count: 0) == 0)
        }
    }
}

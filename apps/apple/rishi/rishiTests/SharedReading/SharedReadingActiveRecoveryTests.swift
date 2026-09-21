import Foundation
import Testing

@testable import rishi

@Suite("Shared reading active recovery")
struct SharedReadingActiveRecoveryTests {
    @Test("recovery is ready only after authoritative state roster and explicit progress result")
    func readinessRequiresAuthoritativeTuple() {
        var readiness = SharedReadingRecoveredSessionReadiness()

        #expect(readiness.isReady == false)
        readiness.accept(.state)
        readiness.accept(.roster)
        #expect(readiness.isReady == false)
        readiness.accept(.progressAbsent)
        #expect(readiness.isReady == true)
    }

    @Test("a newer room epoch invalidates previously accepted recovery frames")
    func newerEpochResetsReadiness() {
        var readiness = SharedReadingRecoveredSessionReadiness(roomEpoch: 1)
        readiness.accept(.state)
        readiness.accept(.roster)
        readiness.accept(.progressPresent(sequence: 4))
        #expect(readiness.isReady == true)

        readiness.begin(roomEpoch: 2)
        #expect(readiness.isReady == false)
    }

    @Test("a late replay requires an authoritative no-progress marker before controls unlock")
    func lateReplayDoesNotImplyNoProgress() {
        var readiness = SharedReadingRecoveredSessionReadiness()
        readiness.accept(.state)
        readiness.accept(.roster)

        #expect(readiness.isReady == false)
        readiness.accept(.progressPresent(sequence: 8))
        #expect(readiness.isReady == true)
    }
}

@testable import rishi
import Testing

@Suite("RealtimeEventPump")
struct RealtimeEventPumpTests {
    @Test("old-generation callbacks cannot suppress IDs in a new generation")
    func staleGenerationCannotMutateDedupeSet() {
        let deduper = RealtimeEventPumpCallIDDeduper()
        let oldGeneration = deduper.beginGeneration()
        #expect(deduper.markEmittedIfCurrent("call", generation: oldGeneration))

        let newGeneration = deduper.beginGeneration()

        #expect(!deduper.markEmittedIfCurrent("call", generation: oldGeneration))
        #expect(deduper.markEmittedIfCurrent("call", generation: newGeneration))
        #expect(!deduper.markEmittedIfCurrent("call", generation: newGeneration))
    }
}

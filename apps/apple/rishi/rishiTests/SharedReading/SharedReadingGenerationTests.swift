import Testing

@testable import rishi

@Suite("Shared reading authority generations")
struct SharedReadingGenerationTests {
    @Test("generation dimensions cannot be compared across protocol domains")
    func generationDimensionsAreDistinct() {
        let room = SharedReadingRoomEpoch(rawValue: 4)
        let roster = SharedReadingRosterGeneration(rawValue: 4)
        let controller = SharedReadingControllerGeneration(rawValue: 4)
        let connection = SharedReadingConnectionGeneration(rawValue: 4)

        #expect(room.rawValue == roster.rawValue)
        #expect(controller.rawValue == connection.rawValue)
    }
}

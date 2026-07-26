













import Foundation
import Testing

@testable import rishi

@Suite("ReadAheadCoordinator")
@MainActor
struct ReadAheadCoordinatorTests {

    
    
    actor RecordingChunkSource: TTSChunkSource {
        private(set) var requested: [TTSStreamRequest] = []

        func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
            requested.append(request)
            return AsyncThrowingStream { $0.finish() }
        }

        func snapshot() -> [TTSStreamRequest] { requested }
    }

    
    
    private func waitForRequests(
        _ source: RecordingChunkSource,
        count: Int,
        timeout: TimeInterval = 2
    ) async -> [TTSStreamRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = await source.snapshot()
            if snap.count >= count { return snap }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await source.snapshot()
    }

    @Test("warms exactly the next readAhead paragraphs after the play head")
    func warmsWindowAfterIndex() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 2)
        let paragraphs = ["a", "b", "c", "d", "e"]

        await coordinator.warm(after: 0, in: paragraphs, voice: "v", model: "eleven_v3", speed: 1.0)

        let requested = await waitForRequests(source, count: 2)
        
        #expect(requested.map { $0.text } == ["b", "c"])
        
        #expect(requested.allSatisfy { $0.passageId == nil })
        #expect(requested.allSatisfy { $0.voice == "v" && $0.model == "eleven_v3" && $0.speed == 1.0 })
    }

    @Test("clamps the window to the end of the batch")
    func clampsWindowAtEnd() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 5)
        let paragraphs = ["a", "b", "c"]

        
        await coordinator.warm(after: 1, in: paragraphs, voice: "v", model: "eleven_v3", speed: 1.0)

        let requested = await waitForRequests(source, count: 1)
        #expect(requested.map { $0.text } == ["c"])
    }

    @Test("warms nothing at the last paragraph (empty window)")
    func emptyWindowAtLastParagraph() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 5)
        let paragraphs = ["a", "b", "c"]

        
        await coordinator.warm(after: 2, in: paragraphs, voice: "v", model: "eleven_v3", speed: 1.0)

        
        try? await Task.sleep(nanoseconds: 150_000_000)
        let requested = await source.snapshot()
        #expect(requested.isEmpty)
    }

    @Test("cancelAll completes cleanly and leaves the coordinator reusable")
    func cancelAllIsCleanAndReusable() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 3)

        
        
        await coordinator.warm(after: 0, in: ["a", "b", "c", "d"], voice: "v", model: "eleven_v3", speed: 1.0)
        await coordinator.cancelAll()  

        
        
        
        await coordinator.warm(after: 0, in: ["x", "y"], voice: "v", model: "eleven_v3", speed: 1.0)
        let deadline = Date().addingTimeInterval(2)
        var sawY = false
        while Date() < deadline {
            if await source.snapshot().contains(where: { $0.text == "y" }) {
                sawY = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawY)
    }
}

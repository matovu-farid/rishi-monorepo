




















import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge seam")
@MainActor
struct ReaderTTSBridgeSeamSmokeTests {

    
    
    
    private struct NoopChunkSource: TTSChunkSource {
        func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test("bridge is constructible with a fake engine and emits passage zero")
    func bridge_is_constructible_with_fake_engine_and_emits_passage_zero() async {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state)
        let tracker = TTSPassageTracker()
        let prewarmer = TTSPrewarmer(source: NoopChunkSource())
        let settingsStore = InMemoryTTSSettingsStore()
        let userId = UserID()

        let recorder = PassageRecorder()
        let bridge = ReaderTTSBridge(
            engine: engine,
            state: state,
            tracker: tracker,
            prewarmer: prewarmer,
            settingsStore: settingsStore,
            userId: userId,
            onPassageChange: { index in
                if let index { recorder.record(index) }
            }
        )

        await bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        
        
        
        for _ in 0..<50 {
            if recorder.recorded.contains(0) { break }
            try? await Task.sleep(nanoseconds: 10_000_000) 
        }

        await bridge.stop()

        #expect(recorder.recorded.contains(0))
    }
}





@MainActor
private final class PassageRecorder {
    private(set) var recorded: [Int] = []
    func record(_ index: Int) { recorded.append(index) }
}

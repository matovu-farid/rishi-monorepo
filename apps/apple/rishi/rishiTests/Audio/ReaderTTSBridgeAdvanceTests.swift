


















import Foundation
import Testing


@testable import rishi

@Suite("ReaderTTSBridge advance")
@MainActor
struct ReaderTTSBridgeAdvanceTests {

    @Test("advances 0 -> 1 -> 2 in order and tears down at the end")
    func advancesThroughParagraphsAndTearsDown() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        
        
        
        
        
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1, 2] }

        await env.bridge.stop()

        
        #expect(env.recorder.nonNilIndices == [0, 1, 2])
        #expect(env.recorder.sawTeardown)
        
        #expect(env.recorder.nonNilIndices.allSatisfy { (0...2).contains($0) })
        
        #expect(env.state.status != .error)
    }

    
    
    
    
    
    
    @Test("prewarmedFast short paragraphs still advance (epub-tts-premature-stop round 2)")
    func prewarmedFastParagraphsStillAdvance() async {
        let env = makeBridge(engine: { state in
            FakeTTSEngine(
                state: state,
                default: .prewarmedFast,
                scriptsByPassageId: ["0": .normal]
            )
        })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        
        
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1, 2] }

        await env.bridge.stop()

        
        #expect(env.recorder.nonNilIndices.contains(2))
        #expect(env.recorder.nonNilIndices == [0, 1, 2])
        #expect(env.recorder.sawTeardown)
    }

    
    
    
    
    
    @Test("continues into the next batch on exhaustion instead of stopping")
    func continuesIntoNextBatchOnExhaustion() async {
        
        let source = ExhaustionSource([["delta", "echo"]])
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .normal) },
            onExhausted: { source.next() }
        )

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        
        
        await waitUntil(timeout: 6) { startedPassageIds(env.engine).count == 5 }

        await env.bridge.stop()

        
        
        #expect(startedPassageIds(env.engine) == ["0", "1", "2", "0", "1"])
        
        #expect(source.callCount >= 1)
        #expect(env.state.status != .error)
    }

    
    
    
    @Test("tears down at end of book when no further chapter is available")
    func tearsDownAtEndOfBook() async {
        let source = ExhaustionSource([]) 
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .normal) },
            onExhausted: { source.next() }
        )

        await env.bridge.start(paragraphs: ["alpha", "bravo"])

        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1] }
        
        await waitUntil(timeout: 2) { source.callCount >= 1 }

        await env.bridge.stop()

        
        #expect(startedPassageIds(env.engine) == ["0", "1"])
        #expect(source.callCount >= 1)
        #expect(env.recorder.sawTeardown)
    }

    @Test("bails on engine error without advancing past 0")
    func bailsOnErrorWithoutAdvancing() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .error) })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        
        await waitUntil(timeout: 2) { env.state.status == .error }
        
        try? await Task.sleep(nanoseconds: 300_000_000)

        await env.bridge.stop()

        #expect(!env.recorder.nonNilIndices.contains(1))
        #expect(!env.recorder.nonNilIndices.contains(2))
    }

    @Test("bails on typed allowance failure without advancing")
    func bailsOnAllowanceFailureWithoutAdvancing() async {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(
            state: state,
            script: .allowance(.narration(message: "narration exhausted"))
        )
        let tracker = TTSPassageTracker()
        let bridge = ReaderTTSBridge(
            engine: engine,
            state: state,
            tracker: tracker,
            prewarmer: TTSPrewarmer(source: NoopChunkSource()),
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
            onPassageChange: { _ in }
        )

        await bridge.start(paragraphs: ["alpha", "bravo"])
        await waitUntil(timeout: 2) { state.typedFailure != nil }

        #expect(state.typedFailure == .narration(message: "narration exhausted"))
        #expect(startedPassageIds(engine) == ["0"])
        await bridge.stop()
    }
}






struct NoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}




@MainActor
final class PassageChangeRecorder {
    private(set) var events: [Int?] = []

    func record(_ index: Int?) { events.append(index) }

    var nonNilIndices: [Int] { events.compactMap { $0 } }
    var sawTeardown: Bool { events.contains(where: { $0 == nil }) }
}


@MainActor
struct BridgeTestEnv {
    let bridge: ReaderTTSBridge
    let engine: FakeTTSEngine
    let state: TTSPlaybackState
    let recorder: PassageChangeRecorder
}




@MainActor
func makeBridge(
    engine makeEngine: (TTSPlaybackState) -> FakeTTSEngine,
    onExhausted: @escaping () async -> [String] = { [] },
    onBeforeStart: @escaping () async -> [String] = { [] }
) -> BridgeTestEnv {
    let state = TTSPlaybackState()
    let engine = makeEngine(state)
    let tracker = TTSPassageTracker()
    let prewarmer = TTSPrewarmer(source: NoopChunkSource())
    let settingsStore = InMemoryTTSSettingsStore()
    let userId = UserID()
    let configurator = FakeAudioSessionConfigurator()
    let coordinator = AudioSessionCoordinator(configurator: configurator)
    

    let recorder = PassageChangeRecorder()
    let bridge = ReaderTTSBridge(
        engine: engine,
        state: state,
        tracker: tracker,
        prewarmer: prewarmer,
        settingsStore: settingsStore,
        userId: userId,
        coordinator: coordinator,
        onPassageChange: { index in recorder.record(index) },
        onParagraphsExhausted: onExhausted,
        onParagraphsBeforeStart: onBeforeStart
    )

    return BridgeTestEnv(bridge: bridge, engine: engine, state: state, recorder: recorder)
}




@MainActor
final class ExhaustionSource {
    private var batches: [[String]]
    private(set) var callCount = 0

    init(_ batches: [[String]]) { self.batches = batches }

    func next() -> [String] {
        callCount += 1
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}




@MainActor
func startedPassageIds(_ engine: FakeTTSEngine) -> [String] {
    engine.calls.compactMap { call in
        if case .start(let id) = call { return id } else { return nil }
    }
}




@MainActor
func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 50_000_000) 
    }
}

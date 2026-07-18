





























import Foundation
import Testing
import PropertyBased
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge long-lived engine (bug 1 detector)")
@MainActor
struct ReaderTTSBridgeLongLivedEngineTests {

    
    
    
    private struct InfiniteChunkSource: TTSChunkSource {
        func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
            AsyncThrowingStream { _ in }
        }
    }

    
    private struct Env {
        let bridge: ReaderTTSBridge
        let audio: FakeAudioEngine
    }

    @MainActor
    private func makeEnv() -> Env {
        let state = TTSPlaybackState()
        let audio = FakeAudioEngine()
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let engine = TTSEngine(
            streamer: TTSStreamer(source: InfiniteChunkSource()),
            decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
            engine: audio,
            coordinator: coordinator,
            state: state
        )
        let bridge = ReaderTTSBridge(
            engine: engine,
            state: state,
            tracker: TTSPassageTracker(),
            prewarmer: TTSPrewarmer(source: InfiniteChunkSource()),
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            coordinator: coordinator,
            onPassageChange: { _ in }
        )
        return Env(bridge: bridge, audio: audio)
    }

    private func count(_ calls: [FakeAudioEngine.Call], _ kind: FakeAudioEngine.Call) -> Int {
        calls.filter { $0 == kind }.count
    }

    
    
    
    
    @Test("a passage switch keeps the AVAudioEngine running: no stop/attach/(re)start (property-based)")
    func switchDoesNotChurnTheEngine() async {
        await propertyCheck(count: 12, input: Gen.int(in: 3 ... 10), Gen.int(in: 0 ... 8)) { pageCount, rawStart in
            
            let startIndex = max(0, min(rawStart, pageCount - 2))
            let env = makeEnv()
            let paragraphs = (0..<pageCount).map { "p\($0)" }

            await env.bridge.start(paragraphs: paragraphs)
            
            await waitUntil(timeout: 2) { count(env.audio.calls, .start) >= 1 }

            
            
            let resetsBeforeJump = count(env.audio.calls, .resetNode)
            await env.bridge.jump(to: startIndex)
            await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsBeforeJump }

            let stopsAfterStart = count(env.audio.calls, .stop)
            let attachesAfterStart = count(env.audio.calls, .attach)
            let startsAfterStart = count(env.audio.calls, .start)
            let resetsAfterStart = count(env.audio.calls, .resetNode)

            
            await env.bridge.next()
            await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsAfterStart }

            let calls = env.audio.calls
            #expect(count(calls, .stop) == stopsAfterStart,
                    "switch must NOT stop the engine; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .attach) == attachesAfterStart,
                    "switch must NOT re-attach; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .start) == startsAfterStart,
                    "switch must NOT (re)start the engine; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .resetNode) >= 1,
                    "a switch must reset the player node in place; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")

            await env.bridge.stop()
        }
    }
}

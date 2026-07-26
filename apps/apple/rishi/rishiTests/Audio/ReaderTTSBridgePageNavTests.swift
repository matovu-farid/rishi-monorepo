




















import Foundation
import Testing


@testable import rishi

@Suite("ReaderTTSBridge page navigation")
@MainActor
struct ReaderTTSBridgePageNavTests {

    @Test("start index begins playback at the requested passage")
    func startIndexBeginsAtRequestedPassage() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })

        await env.bridge.start(paragraphs: ["a", "b", "c", "d"], startIndex: 2)
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(2) }

        #expect(env.engine.lastStartedPassageId == "2")

        await env.bridge.stop()
    }

    
    
    
    @Test("new page refreshes paragraphs and resets to passage 0 (port of tts-page-navigation.spec)")
    func newPageResetsToPassageZero() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b"])
        
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(1) }

        let countBeforeSecondStart = env.recorder.events.count
        await env.bridge.start(paragraphs: ["x", "y", "z"])
        
        
        
        await waitUntil(timeout: 5) { !env.recorder.nonNilIndices(after: countBeforeSecondStart).isEmpty }

        
        let afterReset = env.recorder.nonNilIndices(after: countBeforeSecondStart)
        #expect(afterReset.first == 0)
        
        #expect(env.engine.lastStartedPassageId == "0")

        await env.bridge.stop()
    }

    
    
    
    
    @Test("page change tears down old session before new start (no bleed)")
    func pageChangeTearsDownOldSessionBeforeNewStart() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b"])
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(0) }

        
        await env.bridge.start(paragraphs: ["x", "y", "z"])

        
        
        let calls = env.engine.calls
        guard let newStartIdx = calls.lastIndex(of: .start(passageId: "0")) else {
            Issue.record("expected a start for passage 0 on the new page")
            await env.bridge.stop()
            return
        }
        let teardownBeforeNewStart = calls[..<newStartIdx].contains(.stop)
        #expect(teardownBeforeNewStart)

        await env.bridge.stop()
    }

    
    
    
    @Test("highlight is always within the current page bounds")
    func highlightAlwaysWithinPageBounds() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 5) { env.recorder.sawTeardown }

        #expect(env.recorder.nonNilIndices.allSatisfy { 0 <= $0 && $0 < 3 })

        await env.bridge.stop()
    }

    
    
    
    @Test("start with empty paragraphs is a no-op (stuck-loop guard, port of T2)")
    func startWithEmptyParagraphsIsNoOp() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: [])
        
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(env.recorder.nonNilIndices.isEmpty)
        let startedSomething = env.engine.calls.contains { call in
            if case .start = call { return true }
            return false
        }
        #expect(!startedSomething)
    }

    
    
    
    @Test("jump(to: k) plays paragraph k (port of resume-paragraph / read-aloud-from-selection)")
    func jumpPlaysTargetParagraph() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b", "c", "d"])
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(0) }

        let countBeforeJump = env.recorder.events.count
        await env.bridge.jump(to: 2)
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices(after: countBeforeJump).contains(2) }

        #expect(env.engine.lastStartedPassageId == "2")
        #expect(env.recorder.nonNilIndices.contains(2))

        await env.bridge.stop()
    }
}



extension FakeTTSEngine {
    
    var lastStartedPassageId: String? {
        for call in calls.reversed() {
            if case let .start(passageId) = call { return passageId }
        }
        return nil
    }
}

extension PassageChangeRecorder {
    
    
    func nonNilIndices(after count: Int) -> [Int] {
        guard count <= events.count else { return [] }
        return events[count...].compactMap { $0 }
    }
}

@testable import rishi
import Testing
import Foundation


/// Behavioral contract for ``ChatStreamingState``.
///
/// All mutations must be reachable only from a ``@MainActor`` context — the
/// suite itself is `@MainActor` so a compile-time failure here would mean the
/// class slipped its actor isolation.
@MainActor
@Suite("ChatStreamingState")
struct ChatStreamingStateTests {

    @Test("initial state: not streaming, nil message, nil error")
    func initialState() {
        let state = ChatStreamingState()
        #expect(state.isStreaming == false)
        #expect(state.streamingMessage == nil)
        #expect(state.error == nil)
    }

    @Test("beginStreaming flips isStreaming and seeds an empty buffer")
    func beginStreaming() {
        let state = ChatStreamingState()
        state.beginStreaming()
        #expect(state.isStreaming == true)
        #expect(state.streamingMessage == "")
        #expect(state.error == nil)
    }

    @Test("beginStreaming clears any prior error")
    func beginStreamingClearsError() {
        let state = ChatStreamingState()
        state.failStreaming(SampleError.boom)
        #expect(state.error != nil)
        state.beginStreaming()
        #expect(state.error == nil)
    }

    @Test("appendToken accumulates tokens into streamingMessage")
    func appendTokensAccumulate() {
        let state = ChatStreamingState()
        state.beginStreaming()
        state.appendToken("he")
        state.appendToken("llo")
        #expect(state.streamingMessage == "hello")
    }

    @Test("appendToken is a no-op when not streaming")
    func appendTokenNoopWhenIdle() {
        let state = ChatStreamingState()
        state.appendToken("ignored")
        #expect(state.streamingMessage == nil)
        #expect(state.isStreaming == false)
    }

    @Test("endStreaming clears isStreaming and streamingMessage")
    func endStreamingClears() {
        let state = ChatStreamingState()
        state.beginStreaming()
        state.appendToken("partial")
        state.endStreaming()
        #expect(state.isStreaming == false)
        #expect(state.streamingMessage == nil)
    }

    @Test("failStreaming records the error and clears streaming")
    func failStreamingRecordsError() {
        let state = ChatStreamingState()
        state.beginStreaming()
        state.appendToken("oops")
        state.failStreaming(SampleError.boom)
        #expect(state.isStreaming == false)
        #expect(state.streamingMessage == nil)
        #expect((state.error as? SampleError) == .boom)
    }
}

private enum SampleError: Error, Equatable { case boom }

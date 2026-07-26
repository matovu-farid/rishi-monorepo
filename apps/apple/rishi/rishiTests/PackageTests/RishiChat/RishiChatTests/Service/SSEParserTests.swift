@testable import rishi
import Testing
import Foundation



@Suite("SSEParser")
struct SSEParserTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test("yields one .token event for a single complete frame")
    func singleCompleteFrame() async {
        let parser = SSEParser()
        let events = await parser.consume(data(#"data: {"delta":"hi"}"# + "\n\n"))
        #expect(events == [.token("hi")])
    }

    @Test("yields two .token events for two complete frames in one buffer")
    func twoCompleteFrames() async {
        let parser = SSEParser()
        let chunk = #"data: {"delta":"hi"}"# + "\n\n" + #"data: {"delta":"!"}"# + "\n\n"
        let events = await parser.consume(data(chunk))
        #expect(events == [.token("hi"), .token("!")])
    }

    @Test("reassembles a frame split across two appends")
    func frameSplitAcrossTwoAppends() async {
        let parser = SSEParser()
        let first = await parser.consume(data(#"data: {"delta":"hel"#))
        #expect(first.isEmpty)
        let second = await parser.consume(data(#"lo"}"# + "\n\n"))
        #expect(second == [.token("hello")])
    }

    @Test("ignores comment line and yields only the data frame")
    func ignoresCommentLine() async {
        let parser = SSEParser()
        let buffer = ": keepalive\n\n" + #"data: {"delta":"x"}"# + "\n\n"
        let events = await parser.consume(data(buffer))
        #expect(events == [.token("x")])
    }

    @Test("ignores blank lines between frames")
    func ignoresBlankLines() async {
        let parser = SSEParser()
        let buffer = "\n\n" + #"data: {"delta":"a"}"# + "\n\n\n\n" + #"data: {"delta":"b"}"# + "\n\n"
        let events = await parser.consume(data(buffer))
        #expect(events == [.token("a"), .token("b")])
    }

    @Test("yields .completed on `data: [DONE]` sentinel")
    func doneSentinel() async {
        let parser = SSEParser()
        let events = await parser.consume(data("data: [DONE]\n\n"))
        #expect(events == [.completed])
    }

    @Test("skips malformed JSON frame without aborting; subsequent valid frame still parsed")
    func malformedJSONSkipped() async {
        let parser = SSEParser()
        let buffer = "data: {not_json}\n\n" + #"data: {"delta":"after"}"# + "\n\n"
        let events = await parser.consume(data(buffer))
        #expect(events == [.token("after")])
    }

    @Test("yields .completed for `{\"done\":true}` JSON frame")
    func doneTrueJSON() async {
        let parser = SSEParser()
        let events = await parser.consume(data(#"data: {"done":true}"# + "\n\n"))
        #expect(events == [.completed])
    }

    @Test("yields .toolCall when frame contains tool_call payload")
    func toolCallFrame() async {
        let parser = SSEParser()
        // Inner JSON: {"name":"x"} as an escaped string value.
        let frame = #"data: {"tool_call":"{\"name\":\"x\"}"}"# + "\n\n"
        let events = await parser.consume(data(frame))
        #expect(events == [.toolCall("{\"name\":\"x\"}")])
    }

    @Test("yields .token(\"\") for zero-length delta split across appends")
    func emptyDeltaSplit() async {
        let parser = SSEParser()
        let first = await parser.consume(data(#"data: {"delta":""}"#))
        #expect(first.isEmpty)
        let second = await parser.consume(data("\n\n"))
        #expect(second == [.token("")])
    }

    @Test("finalize() drains trailing buffered partial frame")
    func finalizeDrainsTrailing() async {
        let parser = SSEParser()
        // No frame terminator yet.
        let mid = await parser.consume(data(#"data: {"delta":"tail"}"#))
        #expect(mid.isEmpty)
        let drained = await parser.finalize()
        #expect(drained == [.token("tail")])
    }
}

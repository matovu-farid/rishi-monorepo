import Foundation



/// Server-Sent Events (SSE) parser for the `/api/chat` byte stream.
///
/// Buffers raw `Data` appended via ``consume(_:)`` and yields complete
/// ``ChatEvent`` values whenever a frame terminator (`\n\n`) is observed.
/// Lifecycle:
///   1. caller does `for try await chunk in workerClient.stream(endpoint)`
///   2. for each chunk: `for event in await parser.consume(chunk) { ... }`
///   3. on stream end, call `await parser.finalize()` to flush any trailing
///      partial frame (typically empty; defensive).
///
/// An actor so concurrent appends from a streaming task are serialized.
///
/// Frame contract (OpenAI-style):
///   - `data: {"delta":"<token>"}\n\n` → `.token(<token>)`
///   - `data: {"done":true}\n\n` → `.completed`
///   - `data: [DONE]\n\n` → `.completed` (literal sentinel)
///   - `data: {"tool_call":"<json>"}\n\n` → `.toolCall(<json>)`
///   - `: <comment>\n\n` → ignored
///   - malformed JSON → logged + skipped (DOES NOT abort the stream)
actor SSEParser {

    private var buffer = Data()
    private let frameTerminator: Data = Data("\n\n".utf8)
    private let decoder = JSONDecoder()

    public init() {}

    /// Append a chunk and return any newly-completed events.
    public func consume(_ chunk: Data) -> [ChatEvent] {
        buffer.append(chunk)
        var events: [ChatEvent] = []
        while let range = buffer.range(of: frameTerminator) {
            let frame = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            for event in parseFrame(frame) {
                events.append(event)
            }
        }
        return events
    }

    /// Drain any buffered partial frame (rare; defensive).
    public func finalize() -> [ChatEvent] {
        guard !buffer.isEmpty else { return [] }
        let trailing = buffer
        buffer.removeAll()
        return parseFrame(trailing)
    }

    // MARK: - Internals

    private func parseFrame(_ frame: Data) -> [ChatEvent] {
        guard let text = String(data: frame, encoding: .utf8), !text.isEmpty else { return [] }
        var events: [ChatEvent] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // SSE field names are case-sensitive and have no leading whitespace,
            // but the value after the colon may have one optional space we trim.
            let line = String(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue } // SSE comment
            guard line.hasPrefix("data:") else { continue }
            var payload = Substring(line.dropFirst("data:".count))
            // Optional single leading space per SSE spec.
            if payload.first == " " { payload = payload.dropFirst() }
            let payloadString = String(payload)
            if payloadString == "[DONE]" {
                events.append(.completed)
                continue
            }
            guard let payloadData = payloadString.data(using: .utf8) else { continue }
            do {
                let chunk = try decoder.decode(ChatResponseChunk.self, from: payloadData)
                if let delta = chunk.delta { events.append(.token(delta)) }
                if let tool = chunk.toolCall { events.append(.toolCall(tool)) }
                if chunk.done == true { events.append(.completed) }
            } catch {
                Log.error("chat.sse.malformed", error: error)
                continue
            }
        }
        return events
    }
}

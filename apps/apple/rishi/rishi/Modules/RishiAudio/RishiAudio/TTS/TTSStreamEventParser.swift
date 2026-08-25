import Foundation


struct TTSStreamChunkFrame: Sendable {
    let requestID: String
    let chunkID: String?
    let index: Int
    let audio: Data
}

private struct TTSStreamFramePayload: Decodable, Sendable {
    let requestID: String
    let chunkID: String?
    let index: Int?
    let audioBase64: String?
    let done: Bool?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case chunkID = "chunk_id"
        case index
        case audioBase64 = "audio_b64"
        case done
    }
}

/// Minimal SSE parser for the TTS worker event stream.
///
/// The worker emits one JSON payload per `data:` frame. We buffer raw bytes
/// until a frame terminator arrives, decode chunk payloads, and skip malformed
/// frames rather than aborting the whole stream.
actor TTSStreamEventParser {

    private var buffer = Data()
    private var sawDone = false
    private let frameTerminator = Data("\n\n".utf8)
    private let decoder = JSONDecoder()

    func consume(_ chunk: Data) -> [TTSStreamChunkFrame] {
        guard !sawDone else { return [] }
        buffer.append(chunk)
        var frames: [TTSStreamChunkFrame] = []
        while let range = buffer.range(of: frameTerminator) {
            let frame = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            frames.append(contentsOf: parseFrame(frame))
            if sawDone {
                buffer.removeAll(keepingCapacity: true)
                break
            }
        }
        return frames
    }

    func finalize() -> [TTSStreamChunkFrame] {
        guard !buffer.isEmpty, !sawDone else { return [] }
        let trailing = buffer
        buffer.removeAll(keepingCapacity: true)
        return parseFrame(trailing)
    }

    private func parseFrame(_ frame: Data) -> [TTSStreamChunkFrame] {
        guard let text = String(data: frame, encoding: .utf8), !text.isEmpty else {
            return []
        }

        var payloadLines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix(":") {
                continue
            }
            guard line.hasPrefix("data:") else {
                continue
            }
            var payload = Substring(line.dropFirst("data:".count))
            if payload.first == " " {
                payload = payload.dropFirst()
            }
            payloadLines.append(String(payload))
        }

        guard !payloadLines.isEmpty else {
            return []
        }

        let payloadString = payloadLines.joined(separator: "\n")
        if payloadString == "[DONE]" {
            sawDone = true
            return []
        }

        guard let payloadData = payloadString.data(using: .utf8) else {
            return []
        }

        do {
            let payload = try decoder.decode(TTSStreamFramePayload.self, from: payloadData)
            if payload.done == true {
                sawDone = true
                return []
            }
            guard
                let index = payload.index,
                let audioBase64 = payload.audioBase64,
                let audio = Data(base64Encoded: audioBase64)
            else {
                Log.error(
                    "tts.sse.malformed",
                    error: NSError(domain: "org.fidexa.rishi.tts", code: 1),
                    diagnostic: TelemetryDiagnostic(
                        feature: "tts",
                        operation: "tts.sse.malformed",
                        stage: "parse",
                        errorCode: "missing_audio_fields"
                    )
                )
                return []
            }
            return [
                TTSStreamChunkFrame(
                    requestID: payload.requestID,
                    chunkID: payload.chunkID,
                    index: index,
                    audio: audio
                )
            ]
        } catch {
            Log.error(
                "tts.sse.malformed",
                error: error,
                diagnostic: TelemetryDiagnostic(
                    feature: "tts",
                    operation: "tts.sse.malformed",
                    stage: "parse",
                    errorCode: "invalid_payload"
                )
            )
            return []
        }
    }
}

import Foundation

// MARK: - Streaming TTS: POST /api/audio/speech

/// `POST /api/audio/speech` — streaming MP3 synthesis. Conforms to
/// ``WorkerStreamingEndpointWithBody`` because the response is consumed as
/// chunks of raw bytes via `WorkerClient.stream(_:)` rather than decoded as
/// a single JSON document.
///
/// Phase 8 (TTS / Read Aloud) is the primary caller — chunks are fed straight
/// into `AVAudioEngine` via `AudioFileStreamOpen` for low-latency playback.
public struct SpeechStreamEndpoint: WorkerStreamingEndpointWithBody {

    public struct Body: Encodable, Sendable, Equatable {
        public let text: String
        public let voice: String
        public let model: String
        public let speed: Double

        public init(
            text: String,
            voice: String,
            model: String = "eleven_v3",
            speed: Double = 1.0
        ) {
            self.text = text
            self.voice = voice
            self.model = model
            self.speed = speed
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/audio/speech"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - Streaming TTS: POST /api/audio/speech/elevenlabs

/// `POST /api/audio/speech/elevenlabs` — ElevenLabs-backed streaming MP3 synthesis.
///
/// Keeps the same request body as the legacy OpenAI route so the reader code can
/// switch providers without changing its local settings model.
public struct ElevenLabsSpeechStreamEndpoint: WorkerStreamingEndpointWithBody {

    public struct Body: Encodable, Sendable, Equatable {
        public let text: String
        public let voice: String
        public let model: String
        public let speed: Double

        public init(
            text: String,
            voice: String,
            model: String = "eleven_v3",
            speed: Double = 1.0
        ) {
            self.text = text
            self.voice = voice
            self.model = model
            self.speed = speed
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/audio/speech/elevenlabs"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - Transcribe: POST /api/audio/transcribe

/// `POST /api/audio/transcribe` — Deepgram-backed STT.
///
/// Phase 8/10 will switch this to a multipart upload (the wire format the
/// worker expects); for now the typed ``Body`` captures the intended shape so
/// feature code can compile against it. The Phase 2 declaration is enough to
/// pin the response type — Phase 8 only needs to swap the encoder.
struct TranscribeEndpoint: WorkerEndpointWithBody {
    public typealias Response = TranscribeResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let audio: Data
        public let mimeType: String

        enum CodingKeys: String, CodingKey {
            case audio
            case mimeType = "mime_type"
        }

        public init(audio: Data, mimeType: String) {
            self.audio = audio
            self.mimeType = mimeType
        }
    }

    public struct TranscribeResponse: Decodable, Sendable, Equatable {
        public let transcript: String
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/audio/transcribe"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

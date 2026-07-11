import Foundation

public enum TTSResponseMode: String, Codable, Sendable, Equatable {
    case raw
    case events
}

// MARK: - Streaming TTS: POST /api/audio/speech

/// `POST /api/audio/speech` — streaming TTS synthesis.
///
/// The app requests `response_mode = "events"` so the worker emits ordered SSE
/// chunk frames with stable ids. The client turns those frames into ordered
/// `TTSChunk` values for caching and playback.
///
/// Phase 8 (TTS / Read Aloud) is the primary caller — the byte stream is
/// reassembled into ordered TTS chunks and fed into `AVAudioEngine` via
/// `AudioFileStreamOpen` for low-latency playback.
public struct SpeechStreamEndpoint: WorkerStreamingEndpointWithBody {

    public struct Body: Encodable, Sendable, Equatable {
        public let text: String
        public let voice: String
        public let model: String
        public let speed: Double
        public let responseMode: TTSResponseMode

        public init(
            text: String,
            voice: String,
            model: String = "eleven_v3",
            speed: Double = 1.0,
            responseMode: TTSResponseMode = .events
        ) {
            self.text = text
            self.voice = voice
            self.model = model
            self.speed = speed
            self.responseMode = responseMode
        }

        enum CodingKeys: String, CodingKey {
            case text
            case voice
            case model
            case speed
            case responseMode = "response_mode"
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/audio/speech"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - Speech options

/// `GET /api/audio/speech/options` — worker-provided picker metadata.
///
/// The app uses this to populate the voice/model pickers from the active
/// backend instead of hardcoding provider-specific catalogs in the client.
public struct SpeechOptionsEndpoint: WorkerEndpoint {
    public typealias Response = SpeechOptionsResponse

    public struct SpeechOptionsResponse: Decodable, Sendable, Equatable {
        public struct Choice: Decodable, Sendable, Equatable {
            public let id: String
            public let name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public let provider: String
        public let voices: [Choice]
        public let models: [Choice]
        public let defaultVoiceID: String
        public let defaultModelID: String

        enum CodingKeys: String, CodingKey {
            case provider
            case voices
            case models
            case defaultVoiceID = "default_voice_id"
            case defaultModelID = "default_model_id"
        }

        public init(
            provider: String,
            voices: [Choice],
            models: [Choice],
            defaultVoiceID: String,
            defaultModelID: String
        ) {
            self.provider = provider
            self.voices = voices
            self.models = models
            self.defaultVoiceID = defaultVoiceID
            self.defaultModelID = defaultModelID
        }
    }

    public let method: HTTPMethod = .GET
    public let path: String = "/api/audio/speech/options"

    public init() {}
}

// MARK: - Streaming TTS: POST /api/audio/speech/elevenlabs

/// `POST /api/audio/speech/elevenlabs` — ElevenLabs-backed streaming TTS.
///
/// Keeps the same request body as the legacy OpenAI route so the reader code can
/// switch providers without changing its local settings model.
public struct ElevenLabsSpeechStreamEndpoint: WorkerStreamingEndpointWithBody {

    public struct Body: Encodable, Sendable, Equatable {
        public let text: String
        public let voice: String
        public let model: String
        public let speed: Double
        public let responseMode: TTSResponseMode

        public init(
            text: String,
            voice: String,
            model: String = "eleven_v3",
            speed: Double = 1.0,
            responseMode: TTSResponseMode = .events
        ) {
            self.text = text
            self.voice = voice
            self.model = model
            self.speed = speed
            self.responseMode = responseMode
        }

        enum CodingKeys: String, CodingKey {
            case text
            case voice
            case model
            case speed
            case responseMode = "response_mode"
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

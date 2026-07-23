import Foundation
import RishiCore
import RealtimeAPI

/// Builds the OpenAI Realtime `Session.Audio` configuration that
/// `RealtimeAPIAdapter` previously inlined in its `connect` closure. Single
/// responsibility: encode the audio format + VAD + voice + noise-reduction
/// params. Pure value type, no I/O — trivially testable.
///
/// `makePCM24kFormat` + `inputNoiseReduction` remain `static` (and `internal`)
/// so the existing `RealtimeAPIAdapterAudioFormatTests` keep pointing at the
/// same symbols via re-export shims on the adapter.
struct RealtimeSessionConfigBuilder: Sendable {

    /// PCM 24kHz audio format used for BOTH input and output.
    ///
    /// The OpenAI Realtime API requires the MIME-style type `"audio/pcm"`; a
    /// bare `"pcm"` is rejected at session-update time ("Invalid value: 'pcm'.
    /// Supported values are: 'audio/pcm', 'audio/pcmu', and 'audio/pcma'."),
    /// which leaves the session non-functional and triggers an endless
    /// reconnect loop. `Session.AudioFormat` has only an internal memberwise
    /// init, so we round-trip JSON to build it from outside the SDK module.
    static func makePCM24kFormat() -> Core.Session.AudioFormat {
        let data = try! JSONSerialization.data(withJSONObject: [
            "rate": 24000,
            "type": "audio/pcm",
        ])
        return try! JSONDecoder().decode(Core.Session.AudioFormat.self, from: data)
    }

    /// OpenAI server-side input noise reduction, on top of the device-side
    /// WebRTC/AVAudioSession processing. near-field suits a held phone or a
    /// headset (mobile); far-field suits a laptop/desktop built-in mic used
    /// hands-free.
    static var inputNoiseReduction: Core.Session.Audio.Input.NoiseReduction {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .farField
        #else
        return .nearField
        #endif
    }

    /// Build the full `Session.Audio` block applied inside the SDK's
    /// `Conversation { session in ... }` builder. Voice + VAD parity with
    /// electron / Spike B (INTEGRATIONS.md:44): server VAD threshold 0.7,
    /// silence 700ms, prefix padding 300ms, voice=alloy, PCM 24kHz.
    func makeSessionAudio(language: String? = "en") -> Core.Session.Audio {
        let pcm24k = Self.makePCM24kFormat()
        let input = Core.Session.Audio.Input(
            format: pcm24k,
            noiseReduction: Self.inputNoiseReduction,
            transcription: .init(model: .gpt4oMini, language: language),
            turnDetection: .serverVad(
                prefixPaddingMs: 300,
                silenceDurationMs: 700,
                threshold: 0.7
            )
        )
        let output = Core.Session.Audio.Output(
            voice: .alloy,
            speed: 1.0,
            format: pcm24k
        )
        return Core.Session.Audio(input: input, output: output)
    }

    /// Build the session instructions for a book-aware voice conversation.
    /// The prompt is intentionally short and direct so the model knows:
    /// - it is in a book reader
    /// - it should call `bookContext` for book-grounded questions
    /// - the current reading state is already available in the snapshot
    func makeInstructions(
        bookContext: BookContextSnapshot?,
        language: String? = "en"
    ) -> String {
        let responseLanguage = Self.languageLabel(for: language)
        var lines: [String] = [
            "You are a voice assistant inside a book reader.",
            "Respond in \(responseLanguage).",
            "When the user asks about the book, quietly check it for relevant passages or supporting details.",
            "Never mention tools, function calls, retrieval, indexing, context windows, prompts, or internal systems to the user.",
            "If checking the book would help, you may briefly say, ‘Let me check the book,’ then continue naturally.",
        ]

        if let outline = bookContext?.outline {
            var bookLine = "Current book: \(outline.title)"
            if let author = outline.author, !author.isEmpty {
                bookLine += " by \(author)"
            }
            lines.append(bookLine)
        }

        if let currentPage = bookContext?.currentPage {
            lines.append("Current page: \(currentPage)")
        }

        if let pageText = bookContext?.pageText, !pageText.isEmpty {
            lines.append("Visible page text: \(pageText)")
        }

        if let activeParagraphText = bookContext?.activeParagraphText, !activeParagraphText.isEmpty {
            lines.append("Active paragraph: \(activeParagraphText)")
        }

        return lines.joined(separator: "\n")
    }

    /// Build the single function tool the voice agent is allowed to call.
    /// The responder expects a `queryText` string and nothing else.
    func makeTools() -> [Core.Tool] {
        [
            .function(
                .init(
                    name: "bookContext",
                    description: "Quietly look up passages and supporting details from the current book. Do not mention this capability or its implementation to the user.",
                    parameters: .object(
                        properties: [
                            "queryText": .string(
                                description: "The question or search query about the book."
                            )
                        ]
                    )
                )
            )
        ]
    }

    /// Apply the audio + book-context configuration to an SDK session.
    func configure(
        session: inout Core.Session,
        bookContext: BookContextSnapshot?,
        language: String? = "en"
    ) {
        session.audio = makeSessionAudio(language: language)
        session.instructions = makeInstructions(bookContext: bookContext, language: language)
        session.tools = makeTools()
        session.toolChoice = Core.Tool.Choice.auto
    }

    private static func languageLabel(for code: String?) -> String {
        switch code {
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "hi": return "Hindi"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "zh": return "Chinese"
        case "ar": return "Arabic"
        case "en", nil: return "English"
        default: return "English"
        }
    }
}

import Testing
import Foundation
import RishiCore
import RealtimeAPI
@testable import RishiVoice

@Suite("RealtimeSessionConfigBuilder")
struct RealtimeSessionConfigBuilderTests {

    @Test("configure(session:bookContext:) sets the book tool and instructions")
    func configureAddsBookContextToolAndInstructions() throws {
        let builder = RealtimeSessionConfigBuilder()
        let bookContext = BookContextSnapshot(
            bookId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            currentPage: 42,
            pageText: "Visible page text",
            outline: BookOutlineDTO(
                title: "The Book",
                author: "Ada Lovelace",
                chapters: ["One", "Two"]
            ),
            activeParagraphText: "Active paragraph"
        )

        let audio = RealtimeSessionConfigBuilder.makePCM24kFormat()
        var session = Core.Session(
            audio: Core.Session.Audio(
                input: .init(format: audio),
                output: .init(voice: .alloy, speed: 1.0, format: audio)
            ),
            instructions: "",
            model: .gptRealtimeMini
        )

        builder.configure(session: &session, bookContext: bookContext)

        #expect(session.audio.input.transcription?.language == "en")
        #expect(session.instructions.contains("Respond in English."))
        #expect(session.instructions.contains("The Book"))
        #expect(session.instructions.contains("Ada Lovelace"))
        #expect(session.instructions.contains("Current page: 42"))
        #expect(session.instructions.contains("Visible page text"))
        #expect(session.instructions.contains("Active paragraph"))
        #expect(session.tools?.count == 1)

        let tool = try #require(session.tools?.first)
        guard case let .function(function) = tool else {
            Issue.record("Expected function tool")
            return
        }
        #expect(function.name == "bookContext")
        #expect(function.description?.contains("current book") == true)

        let schemaJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(function.parameters)
        ) as? [String: Any]
        let properties = schemaJSON?["properties"] as? [String: Any]
        let queryText = properties?["queryText"] as? [String: Any]
        #expect(queryText?["type"] as? String == "string")
    }

    @Test("configure(session:bookContext:language:) uses the selected language")
    func configureUsesSelectedLanguage() throws {
        let builder = RealtimeSessionConfigBuilder()
        let audio = RealtimeSessionConfigBuilder.makePCM24kFormat()
        var session = Core.Session(
            audio: Core.Session.Audio(
                input: .init(format: audio),
                output: .init(voice: .alloy, speed: 1.0, format: audio)
            ),
            instructions: "",
            model: .gptRealtimeMini
        )

        builder.configure(session: &session, bookContext: nil, language: "es")

        #expect(session.audio.input.transcription?.language == "es")
        #expect(session.instructions.contains("Respond in Spanish."))
    }
}

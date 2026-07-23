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
        #expect(session.audio.input.transcription?.model == .gpt4oMini)
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
        #expect(session.instructions.contains("Never mention tools"))
        #expect(!session.instructions.contains("Use the bookContext tool"))

        let schemaJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(function.parameters)
        ) as? [String: Any]
        let properties = schemaJSON?["properties"] as? [String: Any]
        let queryText = properties?["queryText"] as? [String: Any]
        #expect(queryText?["type"] as? String == "string")
    }

    @Test("function tool JSON uses description, not server_description")
    func functionToolEncodesDescriptionKey() throws {
        let tools = RealtimeSessionConfigBuilder().makeTools()
        let tool = try #require(tools.first)
        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["type"] as? String == "function")
        #expect(json?["description"] as? String != nil)
        #expect(json?["server_description"] == nil)
    }

    @Test("session.update wire JSON matches OpenAI Realtime RealtimeFunctionTool shape")
    func sessionUpdateWireJSON() throws {
        let session = RealtimeAPIAdapter().makeConfiguredSession(bookContext: nil)
        let event = ClientEvent.updateSession(session)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let jsonString = String(data: data, encoding: .utf8)!
        #expect(!jsonString.contains("server_description"), "Found server_description in wire JSON: \(jsonString)")

        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(root["type"] as? String == "session.update")

        let sessionObj = try #require(root["session"] as? [String: Any])
        #expect(sessionObj["model"] == nil, "session.update must not include model")
        #expect(sessionObj["type"] as? String == "realtime")

        let tools = try #require(sessionObj["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "bookContext")
        #expect(tools[0]["description"] as? String != nil)
        #expect(tools[0]["server_description"] == nil)

        let parameters = try #require(tools[0]["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect((parameters["properties"] as? [String: Any])?["queryText"] != nil)
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

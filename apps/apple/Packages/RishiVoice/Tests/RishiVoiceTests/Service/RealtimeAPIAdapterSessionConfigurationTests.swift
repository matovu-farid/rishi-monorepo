import Testing
import Foundation
import RishiCore
@testable import RishiVoice

/// Adapter-level regression test for the exact session payload handed to the
/// realtime SDK. This is the narrowest useful check for the current bug:
/// it tells us whether the adapter itself is constructing a book-aware
/// realtime session before any WebRTC/network behavior enters the picture.
@Suite("RealtimeAPIAdapter session configuration")
struct RealtimeAPIAdapterSessionConfigurationTests {

    @Test("Adapter session payload includes book instructions and tool config")
    func configuredSessionIncludesBookContext() {
        let adapter = RealtimeAPIAdapter()
        let bookContext = BookContextSnapshot(
            bookId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            currentPage: 12,
            pageText: "Visible page text",
            outline: BookOutlineDTO(
                title: "The Book",
                author: "Ada Lovelace",
                chapters: ["One"]
            ),
            activeParagraphText: "Active paragraph"
        )

        let session = adapter.makeConfiguredSession(bookContext: bookContext)

        #expect(session.instructions.contains("You are a voice assistant inside a book reader."))
        #expect(session.instructions.contains("Respond in English."))
        #expect(session.instructions.contains("quietly check it for relevant passages"))
        #expect(session.instructions.contains("Never mention tools"))
        #expect(!session.instructions.contains("Use the bookContext tool"))
        #expect(session.instructions.contains("The Book"))
        #expect(session.instructions.contains("Ada Lovelace"))
        #expect(session.instructions.contains("Current page: 12"))
        #expect(session.audio.input.transcription?.language == "en")
        #expect(session.tools?.count == 1)
        #expect(session.toolChoice == .auto)
        #expect(session.model == .gptRealtimeMini)

        let tool = try! #require(session.tools?.first)
        guard case let .function(function) = tool else {
            Issue.record("Expected function tool")
            return
        }
        #expect(function.name == "bookContext")
        #expect(function.description?.contains("current book") == true)
    }

    @Test("Adapter session payload respects a selected language")
    func configuredSessionIncludesSelectedLanguage() {
        let adapter = RealtimeAPIAdapter()
        let session = adapter.makeConfiguredSession(bookContext: nil, language: "es")

        #expect(session.instructions.contains("Respond in Spanish."))
        #expect(session.audio.input.transcription?.language == "es")
    }

    @Test("waitUntilConfiguredSession returns once the configured session appears")
    func waitUntilConfiguredSessionReturnsWhenReady() async throws {
        let readySession = RealtimeAPIAdapter().makeConfiguredSession(bookContext: nil)
        let feeder = SnapshotFeeder([nil, nil, readySession])
        let session = try await RealtimeAPIAdapter.waitUntilConfiguredSession(
            timeout: .milliseconds(250),
            pollInterval: .milliseconds(10)
        ) {
            await feeder.next()
        }
        #expect(session.instructions.contains("quietly check it for relevant passages"))
        #expect(session.tools?.count == 1)
    }

    @Test("waitUntilConfiguredSession throws if the session never becomes ready")
    func waitUntilConfiguredSessionTimesOut() async {
        await #expect(throws: RealtimeClientError.self) {
            try await RealtimeAPIAdapter.waitUntilConfiguredSession(
                timeout: .milliseconds(50),
                pollInterval: .milliseconds(10)
            ) { nil }
        }
    }

    @Test("event-driven session wait returns on the configured snapshot")
    func waitUntilConfiguredSessionReturnsFromStream() async throws {
        let adapter = RealtimeAPIAdapter()
        let readySession = adapter.makeConfiguredSession(bookContext: BookContextSnapshot(
            bookId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            currentPage: 1,
            pageText: "Page",
            outline: nil,
            activeParagraphText: nil
        ))
        let (updates, continuation) = AsyncStream.makeStream(of: type(of: readySession))
        let producer = Task {
            try? await Task.sleep(for: .milliseconds(5))
            continuation.yield(readySession)
            continuation.finish()
        }
        defer { producer.cancel(); continuation.finish() }

        let session = try await RealtimeAPIAdapter.waitUntilConfiguredSession(
            timeout: .seconds(1),
            sessionUpdates: updates
        )
        #expect(session.tools?.count == 1)
    }

    @Test("server-minted prompt is accepted without client session update")
    func serverConfiguredSessionDoesNotRequireLocalPromptText() async throws {
        var serverSession = RealtimeAPIAdapter().makeConfiguredSession(bookContext: nil)
        // The Worker uses the shared prompt renderer. It intentionally does
        // not include the literal Swift tool name in its instructions; the
        // tool definition is the authoritative readiness signal.
        serverSession.instructions = "## Role\nYou are the user's personal teacher.\n## Book lookup"

        let (updates, continuation) = AsyncStream.makeStream(of: type(of: serverSession))
        continuation.yield(serverSession)
        continuation.finish()

        let session = try await RealtimeAPIAdapter.waitUntilConfiguredSession(
            timeout: .seconds(1),
            sessionUpdates: updates
        )
        #expect(session.instructions.contains("Book lookup"))
        #expect(session.tools?.count == 1)
    }
}

private actor SnapshotFeeder<T: Sendable> {
    private var snapshots: [T?]

    init(_ snapshots: [T?]) {
        self.snapshots = snapshots
    }

    func next() -> T? {
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }
}

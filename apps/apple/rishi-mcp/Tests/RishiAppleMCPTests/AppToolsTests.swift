import XCTest
@testable import RishiAppleMCP

final class AppToolsTests: XCTestCase {
    func testWaitForParticipantPreservesElapsedMilliseconds() async throws {
        let driver = ImmediateStateDriver()
        let memory = EmptyMemory()
        let registry = InstanceRegistry(driver: driver, memory: memory)
        let tools = AppTools(driver: driver, registry: registry, memory: memory)
        let definition = try XCTUnwrap(MCPTools.definition(named: "wait_for_participant"))

        let result = try await tools.call(
            tool: definition,
            arguments: .object([
                "app": .string("catalyst"),
                "text": .string("participant"),
                "timeoutMs": .integer(1_000),
            ])
        )

        XCTAssertEqual(result["app"]?.stringValue, "catalyst")
        XCTAssertEqual(result["matched"]?.boolValue, true)
        XCTAssertNotNil(result["elapsedMs"]?.intValue)
    }

    func testCreateReadingSessionReturnsRawTokenAndJoinAcceptsInviteURL() async throws {
        let driver = ReadingSessionDriver()
        let memory = EmptyMemory()
        let registry = InstanceRegistry(driver: driver, memory: memory)
        let tools = AppTools(driver: driver, registry: registry, memory: memory)
        let create = try XCTUnwrap(MCPTools.definition(named: "create_reading_session"))
        let created = try await tools.call(
            tool: create,
            arguments: .object([
                "app": .string("catalyst"),
                "bookIdentifier": .string("Book Title#book-id")
            ])
        )

        XCTAssertEqual(created["invite"]?.stringValue, "rishi://sharing/session?token=abc%2F123")
        XCTAssertEqual(created["inviteToken"]?.stringValue, "abc/123")
        XCTAssertEqual(created["sessionId"]?.stringValue, "session-abc")

        let join = try XCTUnwrap(MCPTools.definition(named: "join_reading_session"))
        _ = try await tools.call(
            tool: join,
            arguments: .object([
                "app": .string("iphone17"),
                "token": .string(created["invite"]?.stringValue ?? "")
            ])
        )
        XCTAssertEqual(driver.openedURLs, ["rishi://sharing/session?token=abc%2F123"])
    }

    func testJoinReadingSessionAcceptsCanonicalHTTPSInviteURL() async throws {
        let driver = ReadingSessionDriver()
        let memory = EmptyMemory()
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: memory), memory: memory)
        let join = try XCTUnwrap(MCPTools.definition(named: "join_reading_session"))

        _ = try await tools.call(
            tool: join,
            arguments: .object([
                "app": .string("iphone17"),
                "token": .string("https://rishi.fidexa.org/sharing/session?token=abc%2F123"),
            ])
        )

        XCTAssertEqual(driver.openedURLs, ["rishi://sharing/session?token=abc%2F123"])
    }

    func testJoinReadingSessionRejectsNonCanonicalOrAmbiguousInviteURLs() async throws {
        let invalidInvites = [
            "https://example.com/sharing/session?token=value",
            "https://rishi.fidexa.org/other?token=value",
            "https://rishi.fidexa.org/sharing/%73ession?token=value",
            "http://rishi.fidexa.org/sharing/session?token=value",
            "https://user@rishi.fidexa.org/sharing/session?token=value",
            "https://rishi.fidexa.org:443/sharing/session?token=value",
            "rishi://example.com/session?token=value",
            "rishi://sharing/other?token=value",
            "https://rishi.fidexa.org/sharing/session?token=first&token=second",
            "https://rishi.fidexa.org/sharing/session?token=value&source=invite",
            "https://rishi.fidexa.org/sharing/session?%74oken=value",
            "https://rishi.fidexa.org/sharing/session?token=value#fragment",
            "https://rishi.fidexa.org/sharing/session?token=value#",
            "https://rishi.fidexa.org/sharing/session?token=",
            "https://rishi.fidexa.org/sharing/session?token=%20",
        ]
        let driver = ReadingSessionDriver()
        let memory = EmptyMemory()
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: memory), memory: memory)
        let join = try XCTUnwrap(MCPTools.definition(named: "join_reading_session"))

        for invite in invalidInvites {
            do {
                _ = try await tools.call(
                    tool: join,
                    arguments: .object([
                        "app": .string("iphone17"),
                        "token": .string(invite),
                    ])
                )
                XCTFail("non-canonical or ambiguous invite must be rejected: \(invite)")
            } catch let error as RegistryError {
                XCTAssertEqual(error.code, .actionNotSupported, invite)
            }
        }

        XCTAssertTrue(driver.openedURLs.isEmpty)
    }

    func testJoinReadingSessionPreservesRawTokenInput() async throws {
        let driver = ReadingSessionDriver()
        let memory = EmptyMemory()
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: memory), memory: memory)
        let join = try XCTUnwrap(MCPTools.definition(named: "join_reading_session"))

        _ = try await tools.call(
            tool: join,
            arguments: .object([
                "app": .string("iphone17"),
                "token": .string("raw/token"),
            ])
        )

        XCTAssertEqual(driver.openedURLs, ["rishi://sharing/session?token=raw%2Ftoken"])
    }

    func testCreateReadingSessionRejectsInviteThatWasAlreadyVisibleBeforeFlow() async throws {
        let stale = "rishi://sharing/session?token=stale"
        let driver = SemanticStateDriver(states: [
            semanticState(tree: "Book Title (stale)", inviteURLs: [stale]),
            semanticState(tree: "Book Title (stale)", inviteURLs: [stale]),
        ])
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: EmptyMemory()), memory: EmptyMemory())
        let create = try XCTUnwrap(MCPTools.definition(named: "create_reading_session"))

        do {
            _ = try await tools.call(tool: create, arguments: .object([
                "app": .string("catalyst"),
                "bookIdentifier": .string("Book Title#book-id"),
            ]))
            XCTFail("stale invite must not be accepted as the newly-created invite")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .stateChanged)
        }
    }

    func testCreateReadingSessionRejectsMultipleVisibleInviteURLs() async throws {
        let first = "rishi://sharing/session?token=first"
        let second = "rishi://sharing/session?token=second"
        let driver = SemanticStateDriver(states: [
            semanticState(tree: "Book Title", inviteURLs: []),
            semanticState(tree: "Book Title (first) (second)", inviteURLs: [first, second]),
        ])
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: EmptyMemory()), memory: EmptyMemory())
        let create = try XCTUnwrap(MCPTools.definition(named: "create_reading_session"))

        do {
            _ = try await tools.call(tool: create, arguments: .object([
                "app": .string("catalyst"),
                "bookIdentifier": .string("Book Title#book-id"),
            ]))
            XCTFail("multiple invite URLs must be rejected as ambiguous")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .stateChanged)
        }
    }

    func testCreateReadingSessionRejectsMalformedInviteToken() async throws {
        let malformed = "rishi://sharing/session?token=valid&token=ambiguous"
        let driver = SemanticStateDriver(states: [
            semanticState(tree: "Book Title", inviteURLs: []),
            semanticState(tree: "Book Title (malformed)", inviteURLs: [malformed]),
        ])
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: EmptyMemory()), memory: EmptyMemory())
        let create = try XCTUnwrap(MCPTools.definition(named: "create_reading_session"))

        do {
            _ = try await tools.call(tool: create, arguments: .object([
                "app": .string("catalyst"),
                "bookIdentifier": .string("Book Title#book-id"),
            ]))
            XCTFail("malformed invite token query must be rejected")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .stateChanged)
        }
    }

    func testWaitForParticipantRejectsAmbiguousSessionAndParticipantSignals() async throws {
        let driver = SemanticStateDriver(states: [
            semanticState(
                tree: "participant",
                sessionIDs: ["session-a", "session-b"],
                rosterSignals: [
                    ["count": .integer(2), "capacity": .integer(5)],
                    ["count": .integer(2), "capacity": .integer(5)],
                ]
            ),
        ])
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: EmptyMemory()), memory: EmptyMemory())
        let wait = try XCTUnwrap(MCPTools.definition(named: "wait_for_participant"))

        do {
            _ = try await tools.call(tool: wait, arguments: .object([
                "app": .string("catalyst"),
                "text": .string("participant"),
                "timeoutMs": .integer(1_000),
            ]))
            XCTFail("ambiguous session or roster signals must be rejected")
        } catch let error as RegistryError {
            XCTAssertEqual(error.code, .stateChanged)
        }
    }

    func testWaitForParticipantReturnsStructuredSessionAndReaderProgress() async throws {
        let driver = SemanticStateDriver(states: [
            semanticState(
                tree: "participant",
                sessionIDs: ["session-a"],
                rosterSignals: [["count": .integer(2), "capacity": .integer(5)]],
                reader: [
                    "chapter": .string("Chapter 2"),
                    "page": .object(["current": .integer(4), "total": .integer(20)]),
                    "progress": .number(0.25),
                ]
            ),
        ])
        let tools = AppTools(driver: driver, registry: InstanceRegistry(driver: driver, memory: EmptyMemory()), memory: EmptyMemory())
        let wait = try XCTUnwrap(MCPTools.definition(named: "wait_for_participant"))

        let result = try await tools.call(tool: wait, arguments: .object([
            "app": .string("catalyst"),
            "text": .string("participant"),
            "timeoutMs": .integer(1_000),
        ]))

        XCTAssertEqual(result["sessionId"]?.stringValue, "session-a")
        XCTAssertEqual(result["participantCount"]?.intValue, 2)
        XCTAssertEqual(result["chapter"]?.stringValue, "Chapter 2")
        XCTAssertEqual(result["page"]?["current"]?.intValue, 4)
        XCTAssertEqual(result["page"]?["total"]?.intValue, 20)
        XCTAssertEqual(result["progress"]?.doubleValue, 0.25)
    }
}

private struct ImmediateStateDriver: AppleAppDriver {
    func listApps() async throws -> [AppInstance] { [] }
    func launch(_ target: String) async throws {}
    func terminate(_ target: String) async throws {}
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue {
        semanticState(tree: "participant joined", sessionIDs: ["session-abc"], rosterSignals: [["count": .integer(2), "capacity": .integer(5)]])
    }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object([:]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue { .object([:]) }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object([:]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object([:]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue { .object([:]) }
}

private struct EmptyMemory: MemorySnapshotting {
    func snapshot(match: String) async throws -> JSONValue { .object([:]) }
}

private final class ReadingSessionDriver: AppleAppDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var stateCalls = 0

    var openedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func listApps() async throws -> [AppInstance] { [] }
    func launch(_ target: String) async throws {}
    func terminate(_ target: String) async throws {}
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue {
        let call = stateCalls
        stateCalls += 1
        if call == 0 {
            return semanticState(tree: "Book Title", inviteURLs: [], sessionIDs: [])
        }
        return semanticState(tree: "Book Title rishi://sharing/session?token=abc%2F123", inviteURLs: ["rishi://sharing/session?token=abc%2F123"], sessionIDs: ["session-abc"])
    }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object([:]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue { .object([:]) }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object([:]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object([:]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue {
        record(url)
        return .object(["ok": .bool(true), "url": .string(url)])
    }

    private func record(_ url: String) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

private actor SemanticStateDriver: AppleAppDriver {
    private let states: [JSONValue]
    private var nextState = 0

    init(states: [JSONValue]) {
        self.states = states
    }

    func listApps() async throws -> [AppInstance] { [] }
    func launch(_ target: String) async throws {}
    func terminate(_ target: String) async throws {}
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue {
        let state = states[min(nextState, states.count - 1)]
        nextState += 1
        return state
    }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object([:]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue { .object([:]) }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object([:]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object([:]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue { .object([:]) }
}

private func semanticState(
    tree: String,
    inviteURLs: [String] = [],
    sessionIDs: [String] = [],
    rosterSignals: [[String: JSONValue]] = [],
    reader: [String: JSONValue] = [:]
) -> JSONValue {
    let semantic: [String: JSONValue] = [
        "inviteURLs": .array(inviteURLs.map(JSONValue.string)),
        "sessionIDs": .array(sessionIDs.map(JSONValue.string)),
        "participantRoster": .array(rosterSignals.map(JSONValue.object)),
        "reader": .object(reader),
    ]
    return .object([
        "accessibility": .object([
            "tree": .string(tree),
            "semantic": .object(semantic),
        ])
    ])
}

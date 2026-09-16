import XCTest
@testable import RishiAppleMCP

final class MCPProtocolTests: XCTestCase {
    func testPublishesStableServerInfoAndEveryExistingTool() async throws {
        let server = MCPServer(toolHandler: StubToolHandler())
        let response = try await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertEqual(response?.result?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertEqual(response?.result?["serverInfo"]?["name"]?.stringValue, "rishi-apple-mcp")

        let list = try await server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let names = list?.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, [
            "list_app_instances", "start_app", "stop_app", "restart_app", "inspect_app_state",
            "read_app_logs", "capture_screenshot", "select_book", "click_text", "create_reading_session",
            "join_reading_session", "wait_for_participant", "send_reader_action", "memory_snapshot",
        ])
    }

    func testToolsCallReturnsTextAndStructuredContent() async throws {
        let handler = StubToolHandler(result: .array([]))
        let server = MCPServer(toolHandler: handler)
        let response = try await server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_app_instances","arguments":{}}}"#)
        XCTAssertEqual(response?.result?["structuredContent"]?.arrayValue, [])
        let content = response?.result?["content"]?.arrayValue
        let firstContent = content?.first ?? .null
        XCTAssertEqual(firstContent["type"]?.stringValue, "text")
        XCTAssertEqual(firstContent["text"]?.stringValue, "[]")
    }

    func testInvalidJSONRPCAndUnknownMethodsUseStableErrors() async throws {
        let server = MCPServer(toolHandler: StubToolHandler())
        let invalidJSON = try await server.handleLine("not json")
        XCTAssertEqual(invalidJSON?.error?["code"]?.intValue, -32700)
        let invalidRequest = try await server.handleLine(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(invalidRequest?.error?["code"]?.intValue, -32600)
        let unknownMethod = try await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#)
        XCTAssertEqual(unknownMethod?.error?["code"]?.intValue, -32601)
        let unknownTool = try await server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        XCTAssertEqual(unknownTool?.error?["code"]?.intValue, -32602)
    }

    func testNotificationsDoNotProduceResponses() async throws {
        let server = MCPServer(toolHandler: StubToolHandler())
        let initialized = try await server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let call = try await server.handleLine(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"list_app_instances","arguments":{}}}"#)
        XCTAssertNil(initialized)
        XCTAssertNil(call)
    }

    func testAcceptsOnlySafeJSONRPCIDsAndPreservesTheirRepresentation() async throws {
        let server = MCPServer(toolHandler: StubToolHandler())
        let requests: [(String, JSONValue)] = [
            (#"{"jsonrpc":"2.0","id":"request-1","method":"ping"}"#, .string("request-1")),
            (#"{"jsonrpc":"2.0","id":9007199254740991,"method":"ping"}"#, .integer(9_007_199_254_740_991)),
            (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, .null),
        ]

        for (request, expectedID) in requests {
            let response = try await server.handleLine(request)
            XCTAssertEqual(response?.value["id"], expectedID, "response changed the request ID")
        }

        let response = try await server.handleLine(#"{"jsonrpc":"2.0","id":9007199254740991,"method":"ping"}"#)
        let responseData = try XCTUnwrap(response?.data)
        XCTAssertTrue(String(decoding: responseData, as: UTF8.self).contains("9007199254740991"))
    }

    func testRejectsInvalidJSONRPCIDTypesAndUnsafeNumbers() async throws {
        let server = MCPServer(toolHandler: StubToolHandler())
        let invalidIDs = ["true", "{}", "[]", "1.5", "1.0", "9007199254740992", "-9007199254740992"]

        for invalidID in invalidIDs {
            let response = try await server.handleLine(#"{"jsonrpc":"2.0","id":__ID__,"method":"ping"}"#.replacingOccurrences(of: "__ID__", with: invalidID))
            XCTAssertEqual(response?.error?["code"]?.intValue, -32600, "accepted invalid ID \(invalidID)")
            XCTAssertEqual(response?.value["id"], .null, "echoed invalid ID \(invalidID)")
        }
    }

    func testArgumentValidationRejectsMissingUnknownAndInvalidValues() throws {
        let start = try XCTUnwrap(MCPTools.definition(named: "start_app"))
        XCTAssertThrowsError(try MCPTools.validate(start, arguments: .object([:]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing required argument: app"))
        }
        XCTAssertThrowsError(try MCPTools.validate(start, arguments: .object(["app": .string("catalyst"), "extra": .bool(true)])))
        XCTAssertThrowsError(try MCPTools.validate(start, arguments: .object(["app": .string("ipad")])))
        let restart = try XCTUnwrap(MCPTools.definition(named: "restart_app"))
        XCTAssertThrowsError(try MCPTools.validate(restart, arguments: .object(["app": .string("catalyst"), "confirm": .bool(false)])))
    }

    func testClickTextPreservesOptionalAccessibilityIndex() async throws {
        let driver = RecordingDriver()
        let registry = InstanceRegistry(driver: driver, memory: FakeMemory())
        let tools = AppTools(driver: driver, registry: registry, memory: FakeMemory())
        let tool = try XCTUnwrap(MCPTools.definition(named: "click_text"))

        _ = try await tools.call(tool: tool, arguments: .object([
            "app": .string("catalyst"),
            "text": .string("Continue"),
            "index": .integer(2),
        ]))

        let request = await driver.lastRequest
        XCTAssertEqual(request?.payload["op"]?.stringValue, "tapText")
        XCTAssertEqual(request?.payload["text"]?.stringValue, "Continue")
        XCTAssertEqual(request?.payload["index"]?.intValue, 2)
    }
}

private struct StubToolHandler: MCPToolHandling, Sendable {
    let result: JSONValue
    init(result: JSONValue = .array([])) { self.result = result }
    func call(tool: MCPToolDefinition, arguments: JSONValue) async throws -> JSONValue { result }
}

private actor RecordingDriver: AppleAppDriver {
    struct Request: Sendable {
        let payload: JSONValue
    }

    var lastRequest: Request?

    func listApps() async throws -> [AppInstance] { [] }
    func launch(_ target: String) async throws {}
    func terminate(_ target: String) async throws {}
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue { .object([:]) }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object([:]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue {
        lastRequest = Request(payload: payload)
        return .object(["ok": .bool(true)])
    }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object([:]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object([:]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue { .object([:]) }
}

private struct FakeMemory: MemorySnapshotting, Sendable {
    func snapshot(match: String) async throws -> JSONValue { .object([:]) }
}

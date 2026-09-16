import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(data: Data) throws {
        var parser = JSONValueParser(data: data)
        self = try parser.parse()
    }

    public var data: Data { get throws { try JSONEncoder().encode(self) } }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let value) = self, value.indices.contains(index) else { return nil }
        return value[index]
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value):
            guard value.isFinite, value.rounded() == value else { return nil }
            return Int(exactly: value)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    public static func integer(_ value: Int) -> JSONValue { .integer(Int64(value)) }
}

private struct JSONValueParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> JSONValue {
        try skipWhitespace()
        let value = try parseValue()
        try skipWhitespace()
        guard index == bytes.count else { throw ParserError.invalidJSON }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = peek else { throw ParserError.invalidJSON }
        switch byte {
        case 110: try consumeLiteral("null"); return .null
        case 116: try consumeLiteral("true"); return .bool(true)
        case 102: try consumeLiteral("false"); return .bool(false)
        case 34: return .string(try parseString())
        case 91: return try parseArray()
        case 123: return try parseObject()
        case 45, 48...57: return try parseNumber()
        default: throw ParserError.invalidJSON
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume(91)
        try skipWhitespace()
        var values: [JSONValue] = []
        if peek == 93 { index += 1; return .array(values) }
        while true {
            values.append(try parseValue())
            try skipWhitespace()
            if peek == 93 { index += 1; return .array(values) }
            try consume(44)
            try skipWhitespace()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume(123)
        try skipWhitespace()
        var values: [String: JSONValue] = [:]
        if peek == 125 { index += 1; return .object(values) }
        while true {
            guard peek == 34 else { throw ParserError.invalidJSON }
            let key = try parseString()
            try skipWhitespace()
            try consume(58)
            try skipWhitespace()
            values[key] = try parseValue()
            try skipWhitespace()
            if peek == 125 { index += 1; return .object(values) }
            try consume(44)
            try skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(34)
        while let byte = peek {
            index += 1
            if byte == 34 {
                let data = Data(bytes[(start)..<index])
                return try JSONDecoder().decode(String.self, from: data)
            }
            if byte == 92 {
                guard index < bytes.count else { throw ParserError.invalidJSON }
                index += 1
            } else if byte < 32 {
                throw ParserError.invalidJSON
            }
        }
        throw ParserError.invalidJSON
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if peek == 45 { index += 1 }
        if peek == 48 { index += 1 }
        else {
            guard let byte = peek, byte >= 49, byte <= 57 else { throw ParserError.invalidJSON }
            while let byte = peek, byte >= 48, byte <= 57 { index += 1 }
        }
        var isInteger = true
        if peek == 46 {
            isInteger = false
            index += 1
            guard let byte = peek, byte >= 48, byte <= 57 else { throw ParserError.invalidJSON }
            while let byte = peek, byte >= 48, byte <= 57 { index += 1 }
        }
        if peek == 101 || peek == 69 {
            isInteger = false
            index += 1
            if peek == 43 || peek == 45 { index += 1 }
            guard let byte = peek, byte >= 48, byte <= 57 else { throw ParserError.invalidJSON }
            while let byte = peek, byte >= 48, byte <= 57 { index += 1 }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger, let value = Int64(literal) { return .integer(value) }
        guard let value = Double(literal), value.isFinite else { throw ParserError.invalidJSON }
        return .number(value)
    }

    private mutating func skipWhitespace() throws {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek == expected else { throw ParserError.invalidJSON }
        index += 1
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 { try consume(byte) }
    }

    private var peek: UInt8? { bytes.indices.contains(index) ? bytes[index] : nil }

    private enum ParserError: Error { case invalidJSON }
}

public struct MCPToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public var json: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
    }
}

public protocol MCPToolHandling: Sendable {
    func call(tool: MCPToolDefinition, arguments: JSONValue) async throws -> JSONValue
}

public enum MCPTools {
    public static let definitions: [MCPToolDefinition] = [
        tool("list_app_instances", "List running Rishi Apple app instances.", schema()),
        tool("start_app", "Launch one explicit Apple app target; refuses duplicate targets.", appSchema()),
        tool("stop_app", "Stop a server-owned Apple app instance.", appSchema()),
        tool("restart_app", "Stop and relaunch one target after explicit confirmation.", schema(properties: ["app": appProperty, "confirm": .object(["type": .string("boolean"), "const": .bool(true)])], required: ["app", "confirm"])),
        tool("inspect_app_state", "Inspect semantic accessibility state without launching the app.", schema(properties: ["app": appProperty, "identifier": stringProperty, "screenshot": .object(["type": .string("boolean")])], required: ["app"])),
        tool("read_app_logs", "Read the most recent redacted DEBUG logs from one already-running Apple app target.", schema(properties: ["app": appProperty, "limit": integerProperty(minimum: 1, maximum: 500)], required: ["app"])),
        tool("capture_screenshot", "Capture the current app window for test evidence.", appSchema()),
        tool("select_book", "Perform a semantic action on a library book. Use select_to_share for the context-menu flow.", schema(properties: ["app": appProperty, "identifier": stringProperty(minimum: 1), "action": enumProperty(["open", "select_to_share"])], required: ["app", "identifier", "action"])),
        tool("click_text", "Press one visible button or menu item by its exact accessible text without launching another app.", schema(properties: ["app": appProperty, "text": stringProperty(minimum: 1), "index": integerProperty(minimum: 0)], required: ["app", "text"])),
        tool("create_reading_session", "Drive the visible shared-reading composer for a selected book.", schema(properties: ["app": appProperty, "bookIdentifier": stringProperty(minimum: 1)], required: ["app", "bookIdentifier"])),
        tool("join_reading_session", "Open the app's supported shared-reading session deep link with an explicitly supplied invite token.", schema(properties: ["app": appProperty, "token": stringProperty(minimum: 1)], required: ["app", "token"])),
        tool("wait_for_participant", "Poll visible app state for a participant or session condition.", schema(properties: ["app": appProperty, "text": stringProperty(minimum: 1), "timeoutMs": integerProperty(minimum: 100, maximum: 120_000)], required: ["app", "text"])),
        tool("send_reader_action", "Send a bounded semantic reader action.", schema(properties: ["app": appProperty, "action": enumProperty(["next_page", "previous_page", "pause", "resume", "close"])], required: ["app", "action"])),
        tool("memory_snapshot", "Report host and matching target process memory.", schema(properties: ["app": enumProperty(["", "catalyst", "iphone17"]) ])),
    ]

    public static func definition(named name: String) -> MCPToolDefinition? { definitions.first { $0.name == name } }

    public static func validate(_ tool: MCPToolDefinition, arguments: JSONValue) throws {
        guard case .object(let values) = arguments else { throw ProtocolError.invalidArguments("arguments must be an object") }
        let schema = tool.inputSchema.objectValue ?? [:]
        for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where values[required] == nil {
            throw ProtocolError.invalidArguments("missing required argument: \(required)")
        }
        let properties = schema["properties"]?.objectValue ?? [:]
        for (key, value) in values {
            guard let property = properties[key] else { throw ProtocolError.invalidArguments("unknown argument: \(key)") }
            try validate(value, property: property, key: key)
        }
    }

    private static func validate(_ value: JSONValue, property: JSONValue, key: String) throws {
        let definition = property.objectValue ?? [:]
        if let type = definition["type"]?.stringValue {
            let valid = switch type {
            case "string": value.stringValue != nil
            case "boolean": value.boolValue != nil
            case "integer": value.intValue != nil
            default: true
            }
            guard valid else { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
        }
        if let minLength = definition["minLength"]?.intValue, let string = value.stringValue, string.count < minLength { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
        if let minimum = definition["minimum"]?.doubleValue, let number = value.doubleValue, number < minimum { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
        if let maximum = definition["maximum"]?.doubleValue, let number = value.doubleValue, number > maximum { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
        if let constant = definition["const"], constant != value { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
        if let values = definition["enum"]?.arrayValue, !values.contains(value) { throw ProtocolError.invalidArguments("invalid argument: \(key)") }
    }

    private static let appProperty = enumProperty(["catalyst", "iphone17"])
    private static let stringProperty = stringProperty()
    private static func appSchema() -> JSONValue { schema(properties: ["app": appProperty], required: ["app"]) }
    private static func schema(properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    private static func tool(_ name: String, _ description: String, _ schema: JSONValue) -> MCPToolDefinition { MCPToolDefinition(name: name, description: description, inputSchema: schema) }
    private static func enumProperty(_ values: [String]) -> JSONValue { .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))]) }
    private static func stringProperty(minimum: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string")]
        if let minimum { value["minLength"] = .integer(minimum) }
        return .object(value)
    }
    private static func integerProperty(minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("integer")]
        if let minimum { value["minimum"] = .integer(minimum) }
        if let maximum { value["maximum"] = .integer(maximum) }
        return .object(value)
    }
}

public enum ProtocolError: Error, LocalizedError, Sendable {
    case invalidArguments(String)
    public var errorDescription: String? { if case .invalidArguments(let value) = self { value } else { nil } }
}

public struct MCPResponse: Sendable, Equatable {
    public let value: JSONValue
    public var result: JSONValue? { value["result"] }
    public var error: JSONValue? { value["error"] }
    init(_ value: JSONValue) { self.value = value }
    public var data: Data { get throws { try value.data } }
}

public final class MCPServer: @unchecked Sendable {
    public static let serverInfo: JSONValue = .object(["name": .string("rishi-apple-mcp"), "version": .string("0.1.0")])
    private let toolHandler: any MCPToolHandling

    public init(toolHandler: any MCPToolHandling) { self.toolHandler = toolHandler }

    public func handleLine(_ line: String) async throws -> MCPResponse? {
        guard let data = line.data(using: .utf8) else { return MCPResponse(makeError(id: .null, code: -32700, message: "invalid JSON-RPC request")) }
        let object: [String: JSONValue]
        do { guard case .object(let value) = try JSONValue(data: data) else { throw ProtocolError.invalidArguments("request must be an object") }; object = value }
        catch { return MCPResponse(makeError(id: .null, code: -32700, message: error.localizedDescription)) }
        let notification = object["id"] == nil
        let id: JSONValue
        if let suppliedID = object["id"] {
            guard Self.isValidRequestID(suppliedID) else { return MCPResponse(makeError(id: .null, code: -32600, message: "invalid JSON-RPC request")) }
            id = suppliedID
        } else {
            id = .null
        }
        guard object["jsonrpc"]?.stringValue == "2.0", let method = object["method"]?.stringValue else { return MCPResponse(makeError(id: id, code: -32600, message: "invalid JSON-RPC request")) }
        if method == "notifications/initialized" { return nil }
        if method == "initialize" { return notification ? nil : MCPResponse(success(id: id, result: .object(["protocolVersion": .string("2024-11-05"), "capabilities": .object(["tools": .object([:])]), "serverInfo": Self.serverInfo]))) }
        if method == "ping" { return notification ? nil : MCPResponse(success(id: id, result: .object([:]))) }
        if method == "tools/list" { return notification ? nil : MCPResponse(success(id: id, result: .object(["tools": .array(MCPTools.definitions.map(\.json))]))) }
        guard method == "tools/call" else { return notification ? nil : MCPResponse(makeError(id: id, code: -32601, message: "method not found: \(method)")) }
        let params = object["params"]?.objectValue ?? [:]
        guard let name = params["name"]?.stringValue, let tool = MCPTools.definition(named: name) else { return notification ? nil : MCPResponse(makeError(id: id, code: -32602, message: "unknown tool: \(params["name"]?.stringValue ?? "nil")")) }
        let arguments = params["arguments"] ?? .object([:])
        do {
            try MCPTools.validate(tool, arguments: arguments)
            let result = try await toolHandler.call(tool: tool, arguments: arguments)
            let text = String(data: try result.data, encoding: .utf8) ?? "null"
            return notification ? nil : MCPResponse(success(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "structuredContent": result])))
        } catch {
            let registry = error as? RegistryError
            var data: [String: JSONValue] = ["code": .string(registry?.code.rawValue ?? "TOOL_FAILED")]
            if let extra = registry?.data { data.merge(extra) { _, new in new } }
            return notification ? nil : MCPResponse(makeError(id: id, code: -32000, message: error.localizedDescription, data: .object(data)))
        }
    }

    private func success(id: JSONValue, result: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": result]) }
    private func makeError(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .integer(code), "message": .string(message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }

    private static func isValidRequestID(_ id: JSONValue) -> Bool {
        switch id {
        case .null, .string: return true
        case .integer(let value): return (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value)
        case .bool, .number, .array, .object: return false
        }
    }
}

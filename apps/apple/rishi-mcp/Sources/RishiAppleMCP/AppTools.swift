import Foundation

public struct AppTools: MCPToolHandling, Sendable {
    private let driver: any AppleAppDriver
    private let registry: InstanceRegistry
    private let memory: any MemorySnapshotting
    private let sessionStore = SessionStore()

    public init(driver: any AppleAppDriver, registry: InstanceRegistry, memory: any MemorySnapshotting) {
        self.driver = driver; self.registry = registry; self.memory = memory
    }

    public func call(tool: MCPToolDefinition, arguments: JSONValue) async throws -> JSONValue {
        let values = arguments.objectValue ?? [:]
        let app = values["app"]?.stringValue ?? ""
        switch tool.name {
        case "list_app_instances": return try await registry.list()
        case "start_app": return try await registry.start(app)
        case "stop_app": return try await registry.stop(app)
        case "restart_app": return try await registry.restart(app)
        case "inspect_app_state":
            let state = try await driver.state(app, screenshot: values["screenshot"]?.boolValue ?? false)
            if let identifier = values["identifier"]?.stringValue, !(state["accessibility"]?["tree"]?.stringValue ?? "").localizedCaseInsensitiveContains(identifier) {
                throw RegistryError(.actionNotSupported, "semantic identifier not found: \(identifier)")
            }
            var result: [String: JSONValue] = ["app": .string(app), "state": state["accessibility"] ?? .null, "screenshots": state["screenshots"] ?? .array([])]
            if let semantic = Self.semanticState(from: state) { result["semanticState"] = semantic }
            return .object(result)
        case "read_app_logs": return try await driver.logs(app, limit: values["limit"]?.intValue ?? 200)
        case "capture_screenshot":
            let state = try await driver.state(app, screenshot: true)
            return .object(["app": .string(app), "screenshots": state["screenshots"] ?? .array([])])
        case "select_book":
            let action = values["action"]?.stringValue == "select_to_share" ? "context_menu" : "open"
            return try await driver.clickIdentifier(app, identifier: values["identifier"]?.stringValue ?? "", action: action)
        case "click_text":
            var payload: [String: JSONValue] = ["op": .string("tapText"), "text": .string(values["text"]?.stringValue ?? "")]
            if let index = values["index"]?.intValue { payload["index"] = .integer(index) }
            return try await driver.request(app, payload: .object(payload), timeoutMs: 30_000)
        case "create_reading_session": return try await createReadingSession(app: app, bookIdentifier: values["bookIdentifier"]?.stringValue ?? "")
        case "join_reading_session":
            let token = values["token"]?.stringValue ?? ""
            let rawToken: String
            if token.contains("://") {
                guard let extracted = Self.inviteToken(from: token) else {
                    throw RegistryError(.actionNotSupported, "invite URL did not contain a token")
                }
                rawToken = extracted
            } else {
                rawToken = token
            }
            guard !rawToken.isEmpty else {
                throw RegistryError(.actionNotSupported, "invite token must not be empty")
            }
            let bridge = try await driver.openURL(app, url: Self.sessionURL(token: rawToken))
            await sessionStore.remember(app: app, token: rawToken, sessionID: nil)
            return .object(["app": .string(app), "submitted": .bool(true), "bridge": bridge])
        case "wait_for_participant": return try await waitForParticipant(app: app, timeoutMs: values["timeoutMs"]?.intValue ?? 30_000)
        case "send_reader_action":
            let labels = ["next_page": "Next page", "previous_page": "Previous page", "pause": "Pause", "resume": "Play", "close": "Close"]
            guard let label = labels[values["action"]?.stringValue ?? ""] else { throw RegistryError(.actionNotSupported, "unsupported reader action") }
            return try await driver.clickText(app, text: label)
        case "memory_snapshot": return try await memory.snapshot(match: app)
        default: throw RegistryError(.actionNotSupported, "unsupported tool: \(tool.name)")
        }
    }

    public static func readinessIdentifier(_ bookIdentifier: String) -> String { bookIdentifier.split(separator: "#", maxSplits: 1).first.map(String.init) ?? bookIdentifier }

    public static func sessionURL(token: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = token.utf8.map { byte -> String in
            if byte == 32 { return "+" }
            let character = String(UnicodeScalar(byte))
            if character.rangeOfCharacter(from: allowed) != nil { return character }
            return String(format: "%%%02X", byte)
        }.joined()
        return "rishi://sharing/session?token=\(encoded)"
    }

    private func createReadingSession(app: String, bookIdentifier: String) async throws -> JSONValue {
        let readiness = try await waitForText(app: app, text: Self.readinessIdentifier(bookIdentifier), timeoutMs: 60_000)
        let baselineState = readiness["state"] ?? .null
        let baselineInviteTokens = Self.inviteCandidates(from: baselineState).compactMap(Self.inviteToken(from:))
        _ = try await driver.clickIdentifier(app, identifier: bookIdentifier, action: "context_menu")
        try await pause(milliseconds: 500)
        // Current Apple UI exposes a direct context-menu action. Retain the
        // older selection-toolbar path as a semantic fallback for previously
        // built app binaries used by the MCP smoke tests.
        do {
            _ = try await driver.clickText(app, text: "Start Shared Reading")
        } catch {
            _ = try await driver.clickText(app, text: "Select to Share")
            _ = try await driver.clickText(app, text: "Start reading")
        }
        _ = try await driver.clickText(app, text: "Create reading link")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var state = try await driver.state(app, screenshot: false)
        while ContinuousClock.now < deadline {
            let candidates = Self.inviteCandidates(from: state)
            if !candidates.isEmpty {
                guard candidates.count == 1 else {
                    throw RegistryError(.stateChanged, "reading link state contained multiple invite URLs", data: ["app": .string(app), "bookIdentifier": .string(bookIdentifier)])
                }
                let invite = candidates[0]
                guard let inviteToken = Self.inviteToken(from: invite) else {
                    throw RegistryError(.stateChanged, "reading link did not contain one valid invite token", data: ["app": .string(app), "bookIdentifier": .string(bookIdentifier)])
                }
                guard !baselineInviteTokens.contains(inviteToken) else {
                    throw RegistryError(.stateChanged, "reading link was stale and already visible before creation", data: ["app": .string(app), "bookIdentifier": .string(bookIdentifier)])
                }
                let sessionID = try Self.uniqueSessionID(from: state)
                await sessionStore.remember(app: app, token: inviteToken, sessionID: sessionID)
                var result: [String: JSONValue] = [
                    "app": .string(app),
                    "bookIdentifier": .string(bookIdentifier),
                    "invite": .string(invite),
                    "inviteToken": .string(inviteToken),
                    "state": state["accessibility"] ?? .null,
                ]
                if let sessionID { result["sessionId"] = .string(sessionID) }
                if let semantic = Self.semanticState(from: state) { result["semanticState"] = semantic }
                return .object(result)
            }
            try await pause(milliseconds: 250)
            state = try await driver.state(app, screenshot: false)
        }
        throw RegistryError(.waitTimeout, "reading link did not become visible as one new valid invite", data: ["app": .string(app), "bookIdentifier": .string(bookIdentifier)])
    }

    private func waitForText(app: String, text: String, timeoutMs: Int) async throws -> JSONValue {
        let started = ContinuousClock.now
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
        var last: JSONValue = .null
        while ContinuousClock.now < deadline {
            last = try await driver.state(app, screenshot: false)
            if (last["accessibility"]?["tree"]?.stringValue ?? "").localizedCaseInsensitiveContains(text) {
                let elapsed = started.duration(to: ContinuousClock.now)
                let elapsedMilliseconds = elapsed.components.seconds * 1_000
                    + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
                return .object([
                    "app": .string(app),
                    "matched": .bool(true),
                    "elapsedMs": .integer(Int(elapsedMilliseconds)),
                    "state": last["accessibility"] ?? .null,
                ])
            }
            try await pause(milliseconds: 250)
        }
        throw RegistryError(.waitTimeout, "text not visible before timeout: \(text)", data: ["app": .string(app), "timeoutMs": .integer(timeoutMs), "memory": try await memory.snapshot(match: app)])
    }

    private func waitForParticipant(app: String, timeoutMs: Int) async throws -> JSONValue {
        let started = ContinuousClock.now
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
        while ContinuousClock.now < deadline {
            let state = try await driver.state(app, screenshot: false)
            guard let semantic = Self.semanticState(from: state) else {
                throw RegistryError(.stateChanged, "participant wait requires structured semantic state", data: ["app": .string(app)])
            }
            let sessionID = try Self.uniqueSessionID(from: state, expected: await sessionStore.sessionID(app: app))
            guard let sessionID else {
                throw RegistryError(.stateChanged, "participant wait found no stable session identifier", data: ["app": .string(app)])
            }
            let rosters = Self.rosterSignals(from: semantic)
            guard rosters.count == 1 else {
                throw RegistryError(.stateChanged, "participant wait found an ambiguous participant roster", data: ["app": .string(app)])
            }
            let roster = rosters[0]
            let participantCount = roster["count"]?.intValue ?? 0
            let participantSignal = roster["signal"]?.boolValue ?? (participantCount > 1)
            guard participantSignal && participantCount > 1 else {
                try await pause(milliseconds: 250)
                continue
            }

            let elapsed = started.duration(to: ContinuousClock.now)
            let elapsedMilliseconds = elapsed.components.seconds * 1_000
                + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
            let reader = semantic["reader"] ?? .object([:])
            var result: [String: JSONValue] = [
                "app": .string(app),
                "matched": .bool(true),
                "elapsedMs": .integer(Int(elapsedMilliseconds)),
                "participantCount": .integer(participantCount),
                "participantSignal": .bool(participantSignal),
                "state": state["accessibility"] ?? .null,
                "semanticState": semantic,
            ]
            if let capacity = roster["capacity"]?.intValue { result["participantCapacity"] = .integer(capacity) }
            result["sessionId"] = .string(sessionID)
            if let chapter = reader["chapter"]?.stringValue { result["chapter"] = .string(chapter) }
            if let page = reader["page"]?.objectValue { result["page"] = .object(page) }
            if let progress = reader["progress"]?.doubleValue { result["progress"] = .number(progress) }
            return .object(result)
        }
        throw RegistryError(.waitTimeout, "participant roster did not become ready before timeout", data: ["app": .string(app), "timeoutMs": .integer(timeoutMs), "memory": try await memory.snapshot(match: app)])
    }

    private static func semanticState(from state: JSONValue) -> JSONValue? {
        if let semantic = state["semantic"] { return semantic }
        if let semantic = state["accessibility"]?["semantic"] { return semantic }
        guard let tree = state["tree"]?.stringValue ?? state["accessibility"]?["tree"]?.stringValue,
              let data = tree.data(using: .utf8),
              let envelope = try? JSONValue(data: data) else { return nil }
        return envelope["semantic"]
    }

    private static func inviteCandidates(from state: JSONValue) -> [String] {
        if let semantic = semanticState(from: state) {
            if let values = semantic["inviteURLs"]?.arrayValue {
                return values.compactMap(\.stringValue)
            }
            if let values = semantic["invites"]?.arrayValue {
                return values.compactMap { $0["url"]?.stringValue }
            }
        }

        let text = state["tree"]?.stringValue ?? state["accessibility"]?["tree"]?.stringValue ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"rishi://[^\s'"<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: "),.;"))
        }
    }

    private static func rosterSignals(from semantic: JSONValue) -> [[String: JSONValue]] {
        if let values = semantic["participantRoster"]?.arrayValue {
            return values.compactMap(\.objectValue)
        }
        if let signal = semantic["participantSignal"]?.boolValue {
            var value: [String: JSONValue] = ["signal": .bool(signal)]
            if let count = semantic["participantCount"]?.intValue { value["count"] = .integer(count) }
            return [value]
        }
        return []
    }

    private static func uniqueSessionID(from state: JSONValue, expected: String? = nil) throws -> String? {
        guard let semantic = semanticState(from: state) else { return nil }
        var values = semantic["sessionIDs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let value = semantic["sessionId"]?.stringValue { values.append(value) }
        if let sessions = semantic["sessions"]?.arrayValue {
            values.append(contentsOf: sessions.compactMap { $0["sessionId"]?.stringValue })
        }
        values = values.filter { !$0.isEmpty }
        let unique = Array(Set(values))
        guard unique.count <= 1 else {
            throw RegistryError(.stateChanged, "reading state contained multiple session identifiers", data: ["sessionIDs": .array(unique.map(JSONValue.string))])
        }
        if let observed = unique.first, let expected, observed != expected {
            throw RegistryError(.stateChanged, "reading state belonged to a different session", data: ["expectedSessionId": .string(expected), "observedSessionId": .string(observed)])
        }
        return unique.first ?? expected
    }

    static func inviteToken(from value: String) -> String? {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else { return nil }
        let isCustomInvite = scheme.caseInsensitiveCompare("rishi") == .orderedSame
            && components.host?.caseInsensitiveCompare("sharing") == .orderedSame
            && components.percentEncodedPath == "/session"
        let isCanonicalHTTPSInvite = scheme.caseInsensitiveCompare("https") == .orderedSame
            && components.host?.caseInsensitiveCompare("rishi.fidexa.org") == .orderedSame
            && components.percentEncodedPath == "/sharing/session"
        guard (isCustomInvite || isCanonicalHTTPSInvite),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedFragment == nil,
              let percentEncodedQuery = components.percentEncodedQuery,
              percentEncodedQuery.hasPrefix("token="),
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "token",
              let token = queryItems[0].value,
              !token.isEmpty,
              token.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return token
    }

    private func pause(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

private actor SessionStore {
    private var sessionIDsByApp: [String: String] = [:]
    private var sessionIDsByToken: [String: String] = [:]

    func remember(app: String, token: String, sessionID: String?) {
        if let sessionID {
            sessionIDsByApp[app] = sessionID
            sessionIDsByToken[token] = sessionID
        } else if let sessionID = sessionIDsByToken[token] {
            sessionIDsByApp[app] = sessionID
        }
    }

    func sessionID(app: String) -> String? {
        sessionIDsByApp[app]
    }
}

import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#endif
#if targetEnvironment(macCatalyst)
import CoreGraphics
#endif

final class MCPControlUITests: XCTestCase {
    private static let applicationBundleIdentifier = "org.fidexa.rishi"
    private static var bridgeTarget: String {
        #if targetEnvironment(macCatalyst)
        return "catalyst"
        #else
        return "iphone17"
        #endif
    }

    private static var bridgeConfigPath: String {
        if let configured = ProcessInfo.processInfo.environment["RISHI_MCP_BRIDGE_CONFIG"], !configured.isEmpty {
            return configured
        }
        return ""
    }

    func testInviteURLExtractionRecognizesWebAndDeepLinkInvites() {
        let webInvite = "https://rishi.fidexa.org/sharing/session?token=web-invite"
        let deepLinkInvite = "rishi://sharing/session?token=deep-link-invite"

        XCTAssertEqual(
            MCPControlSemanticState.rishiURLs(in: "Join at \(webInvite) or \(deepLinkInvite)."),
            [webInvite, deepLinkInvite]
        )
    }

    func testInviteURLExtractionDeduplicatesAccessibilityLabelsButKeepsDistinctCandidates() {
        let firstInvite = "https://rishi.fidexa.org/sharing/session?token=first-candidate"
        let secondInvite = "rishi://sharing/session?token=second-candidate"
        let parentLabel = "Invitation link: \(firstInvite)"
        let childLabel = firstInvite
        let otherCandidateLabel = "Another invitation: \(secondInvite)"

        XCTAssertEqual(
            MCPControlSemanticState.inviteURLs(in: [parentLabel, childLabel, otherCandidateLabel]),
            [firstInvite, secondInvite]
        )
    }

    func testSemanticSessionIDsReadAndDeduplicateTheLiveSessionValue() {
        let liveSessionID = "session-for-current-reader"

        XCTAssertEqual(
            MCPControlSemanticState.sessionIDs(from: [
                (identifier: "shared-reading-session-title", value: liveSessionID),
                (identifier: "shared-reading-session-title", value: liveSessionID),
                (identifier: "shared-reading-active-session-\(liveSessionID)", value: nil),
                (identifier: "shared-reading-active-session-stale-list-row", value: nil),
            ]),
            [liveSessionID]
        )
    }

    func testSemanticSessionIDsKeepDistinctActiveSessionCandidates() {
        XCTAssertEqual(
            MCPControlSemanticState.sessionIDs(from: [
                (identifier: "shared-reading-active-session-first", value: nil),
                (identifier: "shared-reading-active-session-second", value: nil),
            ]),
            ["first", "second"]
        )
    }

    @MainActor
    func testServer() throws {
        print("[MCP] bridge test starting")
        guard FileManager.default.fileExists(atPath: Self.bridgeConfigPath) else {
            throw XCTSkip("MCP bridge configuration is created by the external MCP driver.")
        }
        let configData = try Data(contentsOf: URL(fileURLWithPath: Self.bridgeConfigPath))
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let portNumber = config["port"] as? NSNumber else {
            throw BridgeError.message("Invalid MCP bridge configuration.")
        }
        let port = portNumber.uint16Value
        let launchApp = config["launchApp"] as? Bool ?? true
        print("[MCP] bridge config loaded: port=\(port), launchApp=\(launchApp)")
        // Use an explicit proxy because the app is started by simctl/open
        // before this XCTest bridge attaches. The default proxy can remain an
        // unresolved target in that arrangement even while the app is visible.
        let app = XCUIApplication(bundleIdentifier: Self.applicationBundleIdentifier)
        print("[MCP] application handle created")
        app.launchEnvironment["RISHI_UITEST"] = "1"
        if launchApp {
            throw BridgeError.message("The MCP driver must launch the app externally; launchApp=true is unsupported because XCTest launch waits for UI quiescence.")
        }
        print("[MCP] entering bridge loop")

        #if canImport(Darwin)
        while true {
            print("[MCP] connecting to bridge")
            let client = try connectToBridge(port: port)
            print("[MCP] bridge connected")
            defer { close(client) }

            do {
                try configureClient(client)
                let request = try readRequest(from: client)
                let response = try handle(request, app: app)
                try write(response, to: client)
                if request["op"] as? String == "stop" {
                    return
                }
            } catch {
                try? write([
                    "ok": false,
                    "code": "STATE_CHANGED",
                    "error": error.localizedDescription,
                ], to: client)
            }
        }
        #else
        XCTFail("The MCP XCTest bridge requires Darwin sockets.")
        #endif
    }

    #if canImport(Darwin)
    private func connectToBridge(port: UInt16) throws -> Int32 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw BridgeError.message("Could not create MCP bridge socket.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(socketFD)
            throw BridgeError.message("Could not connect to MCP bridge (errno \(errno)).")
        }
        return socketFD
    }

    private func configureClient(_ client: Int32) throws {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
            throw BridgeError.message("Could not configure MCP bridge socket timeout.")
        }
    }

    private func readRequest(from client: Int32) throws -> [String: Any] {
        var bytes = [UInt8](repeating: 0, count: 4096)
        var input = Data()
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(client, buffer.baseAddress, buffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError.message("MCP client disconnected before sending a request.") }
            input.append(bytes, count: count)
            guard input.count <= 1_048_576 else { throw BridgeError.message("MCP bridge request exceeded 1 MiB.") }
            if input.contains(10) { break }
        }
        let line = input.prefix { $0 != 10 }
        guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            throw BridgeError.message("MCP bridge request must be a JSON object.")
        }
        return object
    }

    private func write(_ object: [String: Any], to client: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw BridgeError.message("Could not write empty MCP bridge response.")
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(client, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw BridgeError.message("Could not write MCP bridge response.")
                }
                offset += count
            }
        }
    }

    @MainActor
    private func handle(_ request: [String: Any], app: XCUIApplication) throws -> [String: Any] {
        guard let operation = request["op"] as? String else { throw BridgeError.message("Missing bridge operation.") }
        switch operation {
        case "ping":
            return ["ok": true, "application": Self.bridgeTarget]
        case "snapshot":
            // Screenshots are captured by the MCP driver with simctl or
            // screencapture. XCTest only provides the accessibility tree here;
            // externally launched apps are not valid XCUIApplication screenshot
            // targets and asking XCTest to capture one terminates the bridge.
            let envelope: [String: Any] = [
                "accessibilityTree": app.debugDescription,
                "semantic": semanticSnapshot(for: app),
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            guard let snapshot = String(data: data, encoding: .utf8) else {
                throw BridgeError.message("Could not encode semantic accessibility snapshot.")
            }
            return ["ok": true, "debugDescription": snapshot]
        case "tap":
            guard let requestedIdentifier = request["identifier"] as? String else { throw BridgeError.message("Missing element identifier.") }
            let components = requestedIdentifier.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let identifier = String(components[0])
            let index: Int?
            if components.count == 1 {
                index = nil
            } else if let parsed = Int(components[1]), parsed >= 0 {
                index = parsed
            } else {
                throw BridgeError.message("Invalid element index in identifier \(requestedIdentifier).")
            }
            let matches = app.descendants(matching: .any).matching(identifier: identifier)
            let identifierPredicate = NSPredicate(format: "identifier == %@", identifier)
            let buttonMatches = app.buttons.matching(identifierPredicate)
            let matchCount = max(matches.count, buttonMatches.count)
            guard let index else {
                guard matchCount == 1 else { throw BridgeError.message("Expected one element for identifier \(identifier), found \(matchCount).") }
                let target = matches.count == 1 ? matches.firstMatch : buttonMatches.firstMatch
                if request["action"] as? String == "context_menu" {
                    performContextClick(target)
                } else { target.tap() }
                return ["ok": true, "identifier": requestedIdentifier]
            }
            guard index < matchCount else { throw BridgeError.message("Element index \(index) is out of range for identifier \(identifier), found \(matchCount).") }
            let target = buttonMatches.count > index ? buttonMatches.element(boundBy: index) : matches.element(boundBy: index)
            if request["action"] as? String == "context_menu" {
                performContextClick(target)
            } else { target.tap() }
            return ["ok": true, "identifier": requestedIdentifier]
        case "tapText":
            guard let text = request["text"] as? String else { throw BridgeError.message("Missing visible text.") }
            let requestedIndex = request["index"] as? Int
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@", text, text)
            let exactMenuPredicate = NSPredicate(format: "title == %@ OR label == %@", text, text)
            let exactButtonPredicate = NSPredicate(format: "label == %@ OR title == %@", text, text)
            var matches = app.descendants(matching: .any).matching(predicate)
            var menuMatches = app.menuItems.matching(exactMenuPredicate)
            var buttonMatches = app.buttons.matching(exactButtonPredicate)
            if let requestedIndex {
                let count = buttonMatches.count > 0 ? buttonMatches.count : matches.count
                guard requestedIndex >= 0 && requestedIndex < count else {
                    throw BridgeError.message("Element index is out of range for visible text.")
                }
                if buttonMatches.count > 0 {
                    buttonMatches.element(boundBy: requestedIndex).tap()
                } else {
                    matches.element(boundBy: requestedIndex).tap()
                }
                return ["ok": true, "text": text, "index": requestedIndex, "application": Self.bridgeTarget]
            }
            if buttonMatches.count == 1 || menuMatches.count == 1 || matches.count == 1 {
                let target = menuMatches.count == 1 ? menuMatches.firstMatch : buttonMatches.count == 1 ? buttonMatches.firstMatch : matches.firstMatch
                target.tap()
                return ["ok": true, "text": text, "application": Self.bridgeTarget]
            }

            // Universal-link confirmation alerts are owned by SpringBoard, not by
            // rishi. Keep the normal app lookup first, then allow the MCP bridge
            // to acknowledge a uniquely matching system alert in the simulator.
            #if targetEnvironment(macCatalyst)
            throw BridgeError.message("Expected one visible element containing \(text) in rishi, found \(matches.count) app matches and \(menuMatches.count) menu matches.")
            #else
            let springBoard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let exactSystemPredicate = NSPredicate(format: "label == %@ OR title == %@", text, text)
            let systemMatches = springBoard.descendants(matching: .any).matching(exactSystemPredicate)
            guard systemMatches.count == 1 else {
                throw BridgeError.message("Expected one visible element containing \(text) in rishi or SpringBoard, found \(matches.count) in rishi and \(systemMatches.count) in SpringBoard.")
            }
            systemMatches.firstMatch.tap()
            return ["ok": true, "text": text, "application": "com.apple.springboard"]
            #endif
        case "type":
            guard let text = request["text"] as? String else { throw BridgeError.message("Missing text.") }
            let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            guard field.exists else { throw BridgeError.message("No editable field is visible.") }
            field.tap()
            field.typeText(text)
            return ["ok": true]
        case "openURL":
            guard let value = request["url"] as? String, let url = URL(string: value) else {
                throw BridgeError.message("Missing or invalid URL.")
            }
            app.open(url)
            return ["ok": true, "url": value]
        case "wait":
            guard let text = request["text"] as? String else { throw BridgeError.message("Missing wait text.") }
            let timeout = request["timeoutSeconds"] as? Double ?? 30
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@", text, text)
            let exists = app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
            guard exists else { throw BridgeError.message("Timed out waiting for visible text \(text).") }
            return ["ok": true, "text": text]
        case "stop":
            app.terminate()
            return ["ok": true, "stopped": true]
        default:
            throw BridgeError.message("Unsupported bridge operation \(operation).")
        }
    }

    private func semanticSnapshot(for app: XCUIApplication) -> [String: Any] {
        let accessibilityElements = app.descendants(matching: .any).allElementsBoundByIndex
        var snapshot: [String: Any] = [
            "schema": "rishi.mcp.semantic.v1",
            "inviteURLs": MCPControlSemanticState.inviteURLs(in: accessibilityElements.map(\.label)),
            "sessionIDs": MCPControlSemanticState.sessionIDs(from: accessibilityElements.map {
                (identifier: $0.identifier, value: $0.value as? String)
            }),
        ]

        let rosterSignals = app.descendants(matching: .any)
            .matching(identifier: "shared-reading-readers")
            .allElementsBoundByIndex
            .compactMap(Self.rosterSignal)
        snapshot["participantRoster"] = rosterSignals

        var reader: [String: Any] = [:]
        let pageElements = app.descendants(matching: .any)
            .matching(identifier: "reader.pdf.pageIndicator")
            .allElementsBoundByIndex
        if pageElements.count == 1, let page = Self.pageState(from: pageElements[0].label) {
            reader["page"] = page
        }

        let progressValues = app.descendants(matching: .any).allElementsBoundByIndex.compactMap { element -> Double? in
            guard let match = Self.firstMatch(in: element.label, pattern: #"^(\d{1,3}) percent$"#),
                  let percent = Double(match) else { return nil }
            return min(max(percent / 100, 0), 1)
        }
        if progressValues.count == 1 {
            reader["progress"] = progressValues[0]
        }

        let chapterElements = app.descendants(matching: .any)
            .matching(identifier: "reader.chapter")
            .allElementsBoundByIndex
        if chapterElements.count == 1, !chapterElements[0].label.isEmpty {
            reader["chapter"] = chapterElements[0].label
        }
        snapshot["reader"] = reader
        return snapshot
    }

    private static func rosterSignal(_ element: XCUIElement) -> [String: Any]? {
        guard let match = try? NSRegularExpression(pattern: #"^Readers (\d+)/(\d+)$"#),
              let range = Range(NSRange(location: 0, length: element.label.utf16.count), in: element.label),
              let result = match.firstMatch(in: element.label, range: NSRange(range, in: element.label)),
              let countRange = Range(result.range(at: 1), in: element.label),
              let capacityRange = Range(result.range(at: 2), in: element.label),
              let count = Int(element.label[countRange]),
              let capacity = Int(element.label[capacityRange]) else { return nil }
        return ["count": count, "capacity": capacity, "signal": count > 1]
    }

    private static func pageState(from value: String) -> [String: Any]? {
        guard let current = firstMatch(in: value, pattern: #"^Page (\d+) of (\d+)$"#),
              let total = value.split(separator: " ").last,
              let currentValue = Int(current),
              let totalValue = Int(total) else { return nil }
        return ["current": currentValue, "total": totalValue]
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    @MainActor
    private func performContextClick(_ target: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        // SwiftUI's Catalyst contextMenu responds to the native two-finger /
        // right-button event, while XCUIElement.rightClick() is not dispatched
        // as that event for this view hierarchy. The element is still resolved
        // semantically; only the final platform gesture is emitted here.
        let frame = target.frame
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let scaleX = CGFloat(CGDisplayPixelsWide(display)) / max(bounds.width, 1)
        let scaleY = CGFloat(CGDisplayPixelsHigh(display)) / max(bounds.height, 1)
        // XCUIElement frames are expressed in logical points; CGEvent mouse
        // locations are expressed in backing pixels on a Retina Catalyst host.
        let point = CGPoint(x: frame.midX * scaleX, y: frame.midY * scaleY)
        usleep(500_000)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
        let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        usleep(100_000)
        up?.post(tap: .cghidEventTap)
        #else
        target.press(forDuration: 0.8)
        #endif
    }

    #endif
}

private enum MCPControlSemanticState {
    private static let liveSessionAccessibilityIdentifier = "shared-reading-session-title"
    private static let activeSessionAccessibilityPrefix = "shared-reading-active-session-"

    static func inviteURLs(in labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels
            .flatMap(rishiURLs(in:))
            .filter { seen.insert($0).inserted }
    }

    static func rishiURLs(in value: String) -> [String] {
        let invitePattern = #"(?:https://rishi\.fidexa\.org/sharing/session|rishi://sharing/session)\?token=[^\s'"<>]+"#
        guard let regex = try? NSRegularExpression(pattern: invitePattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        var seen = Set<String>()
        return regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            let url = String(value[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: "),.;"))
            return seen.insert(url).inserted ? url : nil
        }
    }

    static func sessionIDs(from elements: [(identifier: String, value: String?)]) -> [String] {
        var seen = Set<String>()
        let liveSessionIDs = elements.compactMap { element -> String? in
            guard element.identifier == liveSessionAccessibilityIdentifier,
                  let value = element.value,
                  !value.isEmpty,
                  seen.insert(value).inserted else { return nil }
            return value
        }
        if !liveSessionIDs.isEmpty { return liveSessionIDs }

        return elements.compactMap { element in
            guard element.identifier.hasPrefix(activeSessionAccessibilityPrefix) else { return nil }
            let sessionID = String(element.identifier.dropFirst(activeSessionAccessibilityPrefix.count))
            guard !sessionID.isEmpty, seen.insert(sessionID).inserted else { return nil }
            return sessionID
        }
    }
}

private enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

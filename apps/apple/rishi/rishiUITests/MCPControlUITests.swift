import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#endif

final class MCPControlUITests: XCTestCase {
    @MainActor
    func testServer() throws {
        let socketPath = ProcessInfo.processInfo.environment["RISHI_MCP_SOCKET"] ?? "/tmp/rishi-mcp.sock"
        let app = XCUIApplication()
        app.launchEnvironment["RISHI_UITEST"] = "1"
        app.launch()

        #if canImport(Darwin)
        let listener = try makeListener(at: socketPath)
        defer {
            close(listener)
            unlink(socketPath)
        }

        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }

            do {
                try configureClient(client)
                let request = try readRequest(from: client)
                let response = try handle(request, app: app, socketPath: socketPath)
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
    private func makeListener(at path: String) throws -> Int32 {
        unlink(path)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw BridgeError.message("Could not create bridge socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [UInt8(0)]
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else { throw BridgeError.message("Bridge socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw BridgeError.message("Could not bind MCP bridge socket.")
        }
        _ = path.withCString { Darwin.chmod($0, mode_t(0o600)) }
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
    private func handle(_ request: [String: Any], app: XCUIApplication, socketPath: String) throws -> [String: Any] {
        guard let operation = request["op"] as? String else { throw BridgeError.message("Missing bridge operation.") }
        switch operation {
        case "snapshot":
            var response: [String: Any] = ["ok": true, "debugDescription": app.debugDescription]
            if request["screenshot"] as? Bool == true {
                let bridgeDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
                let path = bridgeDirectory.appendingPathComponent("screenshot-\(UUID().uuidString).png")
                try app.screenshot().pngRepresentation.write(to: path)
                response["screenshotPath"] = path.path
            }
            return response
        case "tap":
            guard let identifier = request["identifier"] as? String else { throw BridgeError.message("Missing element identifier.") }
            let matches = app.descendants(matching: .any).matching(identifier: identifier)
            guard matches.count == 1 else { throw BridgeError.message("Expected one element for identifier \(identifier), found \(matches.count).") }
            if request["action"] as? String == "context_menu" {
                #if targetEnvironment(macCatalyst)
                    matches.firstMatch.rightClick()
                #else
                    matches.firstMatch.press(forDuration: 0.8)
                #endif
            } else { matches.firstMatch.tap() }
            return ["ok": true, "identifier": identifier]
        case "tapText":
            guard let text = request["text"] as? String else { throw BridgeError.message("Missing visible text.") }
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@", text, text)
            let matches = app.descendants(matching: .any).matching(predicate)
            guard matches.count == 1 else { throw BridgeError.message("Expected one visible element containing \(text), found \(matches.count).") }
            matches.firstMatch.tap()
            return ["ok": true, "text": text]
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
    #endif
}

private enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

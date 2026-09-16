import Foundation
#if canImport(Darwin)
import Darwin
#endif

private struct FakeDriver: AppleAppDriver, Sendable {
    func listApps() async throws -> [AppInstance] { [] }
    func launch(_ target: String) async throws {}
    func terminate(_ target: String) async throws {}
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue { .object(["accessibility": .object(["tree": .string("")]), "screenshots": .array([])]) }
    func logs(_ target: String, limit: Int) async throws -> JSONValue { .object(["target": .string(target), "entries": .array([])]) }
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue { .object([:]) }
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { .object(["ok": .bool(true)]) }
    func clickText(_ target: String, text: String) async throws -> JSONValue { .object(["ok": .bool(true)]) }
    func openURL(_ target: String, url: String) async throws -> JSONValue { .object(["ok": .bool(true), "url": .string(url)]) }
}

@main
struct RishiAppleMCPMain {
    static func main() async {
        do {
            let memory = MemorySnapshot()
            let driver: any AppleAppDriver = ProcessInfo.processInfo.environment["RISHI_MCP_FAKE"] == "1" ? FakeDriver() : try XCTestDriver()
            let registry = InstanceRegistry(driver: driver, memory: memory)
            let server = MCPServer(toolHandler: AppTools(driver: driver, registry: registry, memory: memory))
            let signalSources = installShutdownSignals(registry: registry)
            while let line = readLine() {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                do { if let response = try await server.handleLine(line) { FileHandle.standardOutput.write(try response.data); FileHandle.standardOutput.write(Data([10])) } }
                catch { FileHandle.standardError.write(Data("rishi-apple-mcp: \(error.localizedDescription)\n".utf8)) }
            }
            signalSources.forEach { $0.cancel() }
            do { try await registry.cleanup() }
            catch { FileHandle.standardError.write(Data("rishi-apple-mcp cleanup: \(error.localizedDescription)\n".utf8)) }
        } catch {
            FileHandle.standardError.write(Data("rishi-apple-mcp: \(error.localizedDescription)\n".utf8))
        }
    }
}

private func installShutdownSignals(registry: InstanceRegistry) -> [DispatchSourceSignal] {
    #if canImport(Darwin)
    return [SIGTERM, SIGINT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
        source.setEventHandler {
            Task {
                do { try await registry.cleanup() }
                catch { FileHandle.standardError.write(Data("rishi-apple-mcp signal cleanup: \(error.localizedDescription)\n".utf8)) }
                Darwin.exit(128 + signalNumber)
            }
        }
        source.resume()
        return source
    }
    #else
    return []
    #endif
}

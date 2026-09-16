import Foundation

public enum RegistryErrorCode: String, Sendable {
    case instanceNotFound = "INSTANCE_NOT_FOUND"
    case instanceAlreadyRunning = "INSTANCE_ALREADY_RUNNING"
    case driverUnavailable = "DRIVER_UNAVAILABLE"
    case actionNotSupported = "ACTION_NOT_SUPPORTED"
    case stateChanged = "STATE_CHANGED"
    case waitTimeout = "WAIT_TIMEOUT"
}

public struct RegistryError: Error, LocalizedError, Sendable {
    public let code: RegistryErrorCode
    public let message: String
    public let data: [String: JSONValue]
    public init(_ code: RegistryErrorCode, _ message: String, data: [String: JSONValue] = [:]) { self.code = code; self.message = message; self.data = data }
    public var errorDescription: String? { message }
}

public struct AppInstance: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isRunning: Bool
    public let windowCount: Int
    public init(id: String, displayName: String, isRunning: Bool, windowCount: Int) { self.id = id; self.displayName = displayName; self.isRunning = isRunning; self.windowCount = windowCount }
    public var json: JSONValue { .object(["id": .string(id), "displayName": .string(displayName), "isRunning": .bool(isRunning), "windows": .array(Array(repeating: .object(["id": .integer(1), "app": .string(id)]), count: windowCount))]) }
}

public protocol AppleAppDriver: Sendable {
    func listApps() async throws -> [AppInstance]
    func launch(_ target: String) async throws
    func terminate(_ target: String) async throws
    func state(_ target: String, screenshot: Bool) async throws -> JSONValue
    func logs(_ target: String, limit: Int) async throws -> JSONValue
    func request(_ target: String, payload: JSONValue, timeoutMs: Int) async throws -> JSONValue
    func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue
    func clickText(_ target: String, text: String) async throws -> JSONValue
    func openURL(_ target: String, url: String) async throws -> JSONValue
}

public protocol MemorySnapshotting: Sendable {
    func snapshot(match: String) async throws -> JSONValue
}

public actor InstanceRegistry {
    private let driver: any AppleAppDriver
    private let memory: any MemorySnapshotting
    private var instances: [String: JSONValue] = [:]
    private var starting: Set<String> = []

    public init(driver: any AppleAppDriver, memory: any MemorySnapshotting) { self.driver = driver; self.memory = memory }

    public func list() async throws -> JSONValue {
        let apps = try await driver.listApps()
        var result: [JSONValue] = []
        for app in apps where app.id.range(of: "rishi", options: .caseInsensitive) != nil && app.isRunning && app.windowCount > 0 {
            var value = app.json.objectValue ?? [:]
            value["owned"] = .bool(instances.values.contains { $0["app"]?.stringValue == app.id })
            value["memory"] = try await memory.snapshot(match: app.id)
            result.append(.object(value))
        }
        return .array(result)
    }

    public func start(_ app: String) async throws -> JSONValue {
        guard !instances.keys.contains(app), !starting.contains(app) else { throw RegistryError(.instanceAlreadyRunning, "target already owned: \(app)", data: ["app": .string(app)]) }
        starting.insert(app)
        defer { starting.remove(app) }
        if let existing = try await driver.listApps().first(where: { $0.id == app && $0.isRunning && $0.windowCount > 0 }) {
            throw RegistryError(.instanceAlreadyRunning, "target already running: \(app)", data: ["app": .string(app), "existing": existing.json])
        }
        try await driver.launch(app)
        let value: JSONValue
        do {
            value = .object(["id": .string("\(app):\(Int(Date().timeIntervalSince1970 * 1000))"), "app": .string(app), "owned": .bool(true), "memory": try await memory.snapshot(match: app)])
        } catch {
            // The driver may have launched a real XCTest/app process before
            // the initial snapshot failed. Do not lose ownership of that
            // process just because the bookkeeping response could not be
            // produced.
            try? await driver.terminate(app)
            throw error
        }
        instances[app] = value
        return value
    }

    public func stop(_ app: String) async throws -> JSONValue {
        guard let instance = instances[app] else { return .object(["app": .string(app), "stopped": .bool(false), "reason": .string("not_owned")]) }
        try await driver.terminate(app)
        instances.removeValue(forKey: app)
        var result = instance.objectValue ?? [:]
        result["stopped"] = .bool(true)
        result["memory"] = try await memory.snapshot(match: app)
        return .object(result)
    }

    public func restart(_ app: String) async throws -> JSONValue {
        if instances[app] != nil { _ = try await stop(app) }
        else if let existing = try await driver.listApps().first(where: { $0.id == app && $0.isRunning && $0.windowCount > 0 }) {
            throw RegistryError(.instanceAlreadyRunning, "refusing to restart unowned target: \(app)", data: ["app": .string(app), "existing": existing.json])
        }
        return try await start(app)
    }

    public func cleanup() async throws {
        var firstError: Error?
        for app in Array(instances.keys) {
            do { _ = try await stop(app) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}

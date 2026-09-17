import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct ResourcePreflightError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ResourcePreflight {
    public static let defaultMinimumDiskBytes: UInt64 = 20 * 1024 * 1024 * 1024
    // A Catalyst build plus an iOS simulator can consume several GiB even
    // after the builds are serialized. Keep a conservative reserve so the
    // runner does not start when the host is already under memory pressure.
    public static let defaultMinimumMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024

    public static func requireSufficient(
        for path: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let disk = try availableDiskBytes(at: path)
        let memory = try availableMemoryBytes()
        let minimumDisk = configuredMinimum(key: "RISHI_E2E_MIN_FREE_DISK_GB", defaultValue: defaultMinimumDiskBytes, environment: environment)
        let minimumMemory = configuredMinimum(key: "RISHI_E2E_MIN_FREE_MEMORY_GB", defaultValue: defaultMinimumMemoryBytes, environment: environment)
        guard disk >= minimumDisk else { throw ResourcePreflightError("Insufficient free disk for Apple E2E: \(format(bytes: disk)) available, \(format(bytes: minimumDisk)) required.") }
        guard memory >= minimumMemory else { throw ResourcePreflightError("Insufficient available memory for Apple E2E: \(format(bytes: memory)) available, \(format(bytes: minimumMemory)) required.") }
    }

    static func configuredMinimum(key: String, defaultValue: UInt64, environment: [String: String]) -> UInt64 {
        // The default remains conservative, but an explicit operator setting
        // is allowed to lower it for a deliberately resource-constrained run.
        // The host still serializes builds and cleans every owned process.
        guard let raw = environment[key], let gigabytes = UInt64(raw), gigabytes > 0 else { return defaultValue }
        return gigabytes * 1024 * 1024 * 1024
    }

    private static func availableDiskBytes(at path: URL) throws -> UInt64 {
        var existing = path
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw ResourcePreflightError("Could not locate a volume for derived-data path \(path.path).") }
            existing = parent
        }
        let values = try existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 { return UInt64(capacity) }
        if let capacity = values.volumeAvailableCapacity, capacity >= 0 { return UInt64(capacity) }
        throw ResourcePreflightError("Could not determine free disk for \(existing.path).")
    }

    private static func availableMemoryBytes() throws -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() }
        catch { throw ResourcePreflightError("Could not inspect available memory with vm_stat.") }
        guard process.terminationStatus == 0 else { throw ResourcePreflightError("Could not inspect available memory with vm_stat.") }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try availableMemoryBytes(from: text)
    }

    static func availableMemoryBytes(from text: String) throws -> UInt64 {
        guard let pageSize = parseValue(in: text, prefix: "page size of") else { throw ResourcePreflightError("Could not parse available memory from vm_stat.") }
        // Purgeable pages are included in inactive pages on macOS; counting
        // them separately would overstate memory available for a heavy build.
        let pages = ["Pages free", "Pages inactive", "Pages speculative"].compactMap { parseValue(in: text, prefix: "\($0):") }.reduce(0, +)
        guard pages > 0 else { throw ResourcePreflightError("Could not parse available memory from vm_stat.") }
        return pages * pageSize
    }

    private static func parseValue(in text: String, prefix: String) -> UInt64? {
        guard let line = text.split(separator: "\n").first(where: { $0.range(of: prefix) != nil }),
              let range = line.range(of: prefix) else { return nil }
        let raw = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first
        return raw.flatMap { UInt64($0.filter(\.isNumber)) }
    }

    private static func format(bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// Cross-process build lock shared by the native E2E host and the Apple MCP.
/// The lock is intentionally fail-closed: an existing directory is never
/// removed automatically because it may belong to a live Xcode process.
public final class AppleXcodeBuildLock: @unchecked Sendable {
    private let lockURL: URL
    private let ownerToken: String
    private let stateLock = NSLock()
    private var released = false

    private init(lockURL: URL, ownerToken: String) {
        self.lockURL = lockURL
        self.ownerToken = ownerToken
    }

    public static func acquire(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppleXcodeBuildLock {
        let configured = environment["RISHI_APPLE_XCODE_BUILD_LOCK_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lockURL: URL
        if let configured, !configured.isEmpty {
            lockURL = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            // Keep this path identical to the standalone capture helper and
            // Swift MCP. NSTemporaryDirectory() is process/environment
            // dependent and would silently create separate lock domains.
            lockURL = URL(fileURLWithPath: "/private/tmp/rishi-apple-xcode-build.lock", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        } catch {
            // A force-quit or interrupted host can leave its lock directory
            // behind after the Xcode child has exited. Recover only when the
            // lock metadata proves its recorded owner PID is dead; missing or
            // malformed metadata remains fail-closed.
            guard recoverStaleLock(at: lockURL) else {
                throw ResourcePreflightError("Another Apple build is using the shared build lock: \(lockURL.path)")
            }
            do {
                try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
            } catch {
                throw ResourcePreflightError("Another Apple build is using the shared build lock: \(lockURL.path)")
            }
        }
        let ownerToken = UUID().uuidString
        do {
            let metadata = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "token": ownerToken,
                "startedAt": ISO8601DateFormatter().string(from: Date()),
            ], options: [.sortedKeys])
            try metadata.write(to: lockURL.appendingPathComponent("owner.json"), options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockURL.path)
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
        return AppleXcodeBuildLock(lockURL: lockURL, ownerToken: ownerToken)
    }

    public func release() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        guard ownsLockDirectory() else {
            released = true
            throw ResourcePreflightError("Apple build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        try FileManager.default.removeItem(at: lockURL)
        released = true
    }

    private func ownsLockDirectory() -> Bool {
        guard let data = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json")),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let token = object["token"] as? String else { return false }
        return token == ownerToken
    }

    private static func recoverStaleLock(at lockURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: lockURL.appendingPathComponent("owner.json")),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let pidNumber = object["pid"] as? NSNumber else {
            return false
        }
        let pid = pidNumber.int32Value
        guard pid > 0, !isProcessAlive(pid) else { return false }
        do {
            try FileManager.default.removeItem(at: lockURL)
            return true
        } catch {
            return false
        }
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return true
        #endif
    }

    deinit { try? release() }
}

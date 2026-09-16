import Foundation

public struct ResourcePreflightError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ResourcePreflight {
    public static let defaultMinimumDiskBytes: UInt64 = 20 * 1024 * 1024 * 1024
    // Keep enough headroom for Xcode and the target process; MCP must refuse
    // to launch a new Apple process when the host is already constrained.
    public static let defaultMinimumMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024

    public static func requireSufficient(
        for path: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let disk = try availableDiskBytes(at: path)
        let memory = try availableMemoryBytes()
        let minimumDisk = configuredMinimum(key: "RISHI_MCP_MIN_FREE_DISK_GB", fallback: "RISHI_E2E_MIN_FREE_DISK_GB", defaultValue: defaultMinimumDiskBytes, environment: environment)
        let minimumMemory = configuredMinimum(key: "RISHI_MCP_MIN_FREE_MEMORY_GB", fallback: "RISHI_E2E_MIN_FREE_MEMORY_GB", defaultValue: defaultMinimumMemoryBytes, environment: environment)
        guard disk >= minimumDisk else { throw ResourcePreflightError("Insufficient free disk for Apple E2E: \(format(bytes: disk)) available, \(format(bytes: minimumDisk)) required.") }
        guard memory >= minimumMemory else { throw ResourcePreflightError("Insufficient available memory for Apple E2E: \(format(bytes: memory)) available, \(format(bytes: minimumMemory)) required.") }
    }

    static func configuredMinimum(key: String, fallback: String, defaultValue: UInt64, environment: [String: String]) -> UInt64 {
        for name in [key, fallback] {
            guard let raw = environment[name], let gigabytes = UInt64(raw), gigabytes > 0 else { continue }
            return max(defaultValue, gigabytes * 1024 * 1024 * 1024)
        }
        return defaultValue
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
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
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

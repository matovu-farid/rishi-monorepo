import Foundation

public struct ResourcePreflightError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct ResourceCapacity: Sendable {
    let diskBytes: UInt64
    let memoryBytes: UInt64?
}

public enum ResourcePreflight {
    public static let defaultMinimumDiskBytes: UInt64 = 20 * 1024 * 1024 * 1024
    typealias CapacityProvider = @Sendable (URL) throws -> ResourceCapacity

    static let systemCapacity: CapacityProvider = { path in
        ResourceCapacity(
            diskBytes: try availableDiskBytes(at: path),
            memoryBytes: nil
        )
    }

    public static func requireSufficient(
        for path: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try requireSufficient(for: path, environment: environment, capacityProvider: systemCapacity)
    }

    static func requireSufficient(
        for path: URL,
        environment: [String: String],
        capacityProvider: CapacityProvider
    ) throws {
        let capacity = try capacityProvider(path)
        let minimumDisk = configuredMinimum(key: "RISHI_MCP_MIN_FREE_DISK_GB", fallback: "RISHI_E2E_MIN_FREE_DISK_GB", defaultValue: defaultMinimumDiskBytes, environment: environment)
        guard capacity.diskBytes >= minimumDisk else { throw ResourcePreflightError("Insufficient free disk for Apple E2E: \(format(bytes: capacity.diskBytes)) available, \(format(bytes: minimumDisk)) required.") }
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

    private static func format(bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

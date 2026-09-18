import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct ResourcePreflightError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct ResourceCapacity: Sendable, Equatable {
    let diskBytes: UInt64
    let memoryBytes: UInt64?
}

typealias ResourceCapacityProvider = @Sendable (URL) throws -> ResourceCapacity

public enum ResourcePreflight {
    public static let defaultMinimumDiskBytes: UInt64 = 20 * 1024 * 1024 * 1024

    public static func requireSufficient(
        for path: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try requireSufficient(for: path, environment: environment, capacityProvider: systemCapacity(at:))
    }

    static func requireSufficient(
        for path: URL,
        environment: [String: String],
        capacityProvider: ResourceCapacityProvider
    ) throws {
        let capacity = try capacityProvider(path)
        let minimumDisk = configuredMinimum(key: "RISHI_E2E_MIN_FREE_DISK_GB", defaultValue: defaultMinimumDiskBytes, environment: environment)
        guard capacity.diskBytes >= minimumDisk else { throw ResourcePreflightError("Insufficient free disk for Apple E2E: \(format(bytes: capacity.diskBytes)) available, \(format(bytes: minimumDisk)) required.") }
    }

    private static func systemCapacity(at path: URL) throws -> ResourceCapacity {
        ResourceCapacity(diskBytes: try availableDiskBytes(at: path), memoryBytes: nil)
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

    private static func format(bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// Cross-process build lock shared by the native E2E host and the Apple MCP.
/// The lock is intentionally fail-closed: an existing directory is never
/// removed automatically because it may belong to a live Xcode process.
public final class AppleXcodeBuildLock: @unchecked Sendable {
    private static let coordinationLock = NSLock()
    private static let metadataFilename = "owner.json"

    private let lockURL: URL
    public let ownership: AppleXcodeBuildLockOwnership
    private let stateLock = NSLock()
    private var released = false
    private var transferredToRecovery = false

    private init(lockURL: URL, ownership: AppleXcodeBuildLockOwnership) {
        self.lockURL = lockURL
        self.ownership = ownership
    }

    public static func acquire(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AppleXcodeBuildLock {
        try coordinationLock.withLock {
            try acquireWhileCoordinated(environment: environment)
        }
    }

    private static func acquireWhileCoordinated(environment: [String: String]) throws -> AppleXcodeBuildLock {
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
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let owner = ProcessIdentityReader.identity(for: pid) else {
            try? FileManager.default.removeItem(at: lockURL)
            throw ResourcePreflightError("Could not establish stable ownership for Apple build lock: \(lockURL.path)")
        }
        let ownership = AppleXcodeBuildLockOwnership(
            path: lockURL.path,
            token: UUID().uuidString,
            generation: UUID().uuidString,
            owner: owner
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(ownership).write(
                to: lockURL.appendingPathComponent(metadataFilename),
                options: [.atomic]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockURL.path)
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
        return AppleXcodeBuildLock(lockURL: lockURL, ownership: ownership)
    }

    public func release() throws {
        try stateLock.withLock {
            guard !released else { return }
            guard !transferredToRecovery else {
                throw ResourcePreflightError("Apple build lock was transferred to recovery: \(lockURL.path)")
            }
            try Self.coordinationLock.withLock {
                try Self.removePresentLock(at: lockURL, matching: ownership)
            }
            released = true
        }
    }

    public func transferToRecovery() -> AppleXcodeBuildLockOwnership {
        stateLock.withLock {
            transferredToRecovery = true
            return ownership
        }
    }

    public static func reconcileRetainedLock(ownership: AppleXcodeBuildLockOwnership) throws {
        try reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: ProcessIdentityReader.identity(for:)
        )
    }

    static func reconcileRetainedLock(
        ownership: AppleXcodeBuildLockOwnership,
        liveIdentity: (Int32) -> OwnedProcessIdentity?
    ) throws {
        try coordinationLock.withLock {
            let lockURL = URL(fileURLWithPath: ownership.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: lockURL.path) else { return }
            guard liveIdentity(ownership.owner.pid) != ownership.owner else {
                throw ResourcePreflightError("Apple build lock owner is still running: \(lockURL.path)")
            }
            try removePresentLock(at: lockURL, matching: ownership)
        }
    }

    private static func recoverStaleLock(at lockURL: URL) -> Bool {
        guard let ownership = try? persistedOwnership(at: lockURL),
              ownership.path == lockURL.path,
              ProcessIdentityReader.identity(for: ownership.owner.pid) != ownership.owner else { return false }
        do {
            try removePresentLock(at: lockURL, matching: ownership)
            return true
        } catch {
            return false
        }
    }

    private static func removePresentLock(
        at lockURL: URL,
        matching ownership: AppleXcodeBuildLockOwnership
    ) throws {
        guard lockURL.path == ownership.path,
              try persistedOwnership(at: lockURL) == ownership else {
            throw ResourcePreflightError("Apple build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        // Re-read immediately before removal so a cooperative replacement
        // cannot be mistaken for the generation validated above.
        guard try persistedOwnership(at: lockURL) == ownership else {
            throw ResourcePreflightError("Apple build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        try FileManager.default.removeItem(at: lockURL)
    }

    private static func persistedOwnership(at lockURL: URL) throws -> AppleXcodeBuildLockOwnership {
        do {
            return try JSONDecoder().decode(
                AppleXcodeBuildLockOwnership.self,
                from: Data(contentsOf: lockURL.appendingPathComponent(metadataFilename))
            )
        } catch {
            throw ResourcePreflightError("Apple build lock metadata is missing or malformed: \(lockURL.path)")
        }
    }

    deinit {
        let shouldRelease = stateLock.withLock { !released && !transferredToRecovery }
        if shouldRelease { try? release() }
    }
}

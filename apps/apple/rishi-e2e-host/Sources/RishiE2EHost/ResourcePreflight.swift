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
    private static let maximumMetadataBytes = 64 * 1024

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
        let lockURL = try configuredLockURL(environment: environment)
        return try coordinationLock.withLock {
            try withCrossProcessCoordination(at: lockURL) { coordination in
                try acquireWhileCoordinated(at: lockURL, coordination: coordination)
            }
        }
    }

    private static func configuredLockURL(environment: [String: String]) throws -> URL {
        let configured = environment["RISHI_APPLE_XCODE_BUILD_LOCK_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let configured, !configured.isEmpty {
            path = configured
        } else {
            // Keep this path identical to the standalone capture helper and
            // Swift MCP. NSTemporaryDirectory() is process/environment
            // dependent and would silently create separate lock domains.
            path = "/private/tmp/rishi-apple-xcode-build.lock"
        }
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.count < Int(PATH_MAX),
              URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path else {
            throw ResourcePreflightError("Apple build lock path must be an absolute, normalized, bounded path: \(path)")
        }
        let lockURL = URL(fileURLWithPath: path, isDirectory: true)
        let coordinationURL = try coordinationURL(for: lockURL)
        guard coordinationURL.path.utf8.count < Int(PATH_MAX) else {
            throw ResourcePreflightError("Apple build lock coordination path is too long: \(coordinationURL.path)")
        }
        return lockURL
    }

    private static func acquireWhileCoordinated(
        at lockURL: URL,
        coordination: Coordination
    ) throws -> AppleXcodeBuildLock {
        guard mkdirat(coordination.parentFD, coordination.lockName, mode_t(0o700)) == 0 else {
            // Acquisition never interprets stale ownership. Only recovery,
            // after proving every journaled resource absent, may reconcile an
            // exact retained generation.
            throw ResourcePreflightError("Another Apple build is using the shared build lock: \(lockURL.path)")
        }
        let lockDirectory = try openLockDirectory(coordination)
        defer { close(lockDirectory.fd) }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let owner = ProcessIdentityReader.identity(for: pid) else {
            try? removeEmptyLockDirectory(lockDirectory, coordination: coordination)
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
            try writeOwnership(encoder.encode(ownership), lockDirectoryFD: lockDirectory.fd)
            guard fchmod(lockDirectory.fd, mode_t(0o700)) == 0,
                  try persistedOwnership(lockDirectoryFD: lockDirectory.fd, lockURL: lockURL) == ownership,
                  validateLockDirectory(lockDirectory, coordination: coordination) else {
                throw ResourcePreflightError("Could not verify Apple build lock ownership: \(lockURL.path)")
            }
        } catch {
            try? removeLockDirectory(lockDirectory, coordination: coordination)
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
                try Self.withCrossProcessCoordination(at: lockURL) { coordination in
                    try Self.removePresentLock(at: lockURL, matching: ownership, coordination: coordination)
                }
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
        try reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: liveIdentity,
            afterValidationBeforeRemoval: {},
            afterCoordinationLockBeforePathValidation: {}
        )
    }

    static func reconcileRetainedLock(
        ownership: AppleXcodeBuildLockOwnership,
        liveIdentity: (Int32) -> OwnedProcessIdentity?,
        afterValidationBeforeRemoval: () -> Void
    ) throws {
        try reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: liveIdentity,
            afterValidationBeforeRemoval: afterValidationBeforeRemoval,
            afterCoordinationLockBeforePathValidation: {}
        )
    }

    static func reconcileRetainedLock(
        ownership: AppleXcodeBuildLockOwnership,
        liveIdentity: (Int32) -> OwnedProcessIdentity?,
        afterCoordinationLockBeforePathValidation: () -> Void
    ) throws {
        try reconcileRetainedLock(
            ownership: ownership,
            liveIdentity: liveIdentity,
            afterValidationBeforeRemoval: {},
            afterCoordinationLockBeforePathValidation: afterCoordinationLockBeforePathValidation
        )
    }

    private static func reconcileRetainedLock(
        ownership: AppleXcodeBuildLockOwnership,
        liveIdentity: (Int32) -> OwnedProcessIdentity?,
        afterValidationBeforeRemoval: () -> Void,
        afterCoordinationLockBeforePathValidation: () -> Void
    ) throws {
        let lockURL = try validatedLockURL(path: ownership.path)
        switch inspectParentDirectory(lockURL.deletingLastPathComponent().path) {
        case .expected: break
        case .absent, .invalid:
            throw ResourcePreflightError("Apple build lock parent is absent or unsafe: \(lockURL.deletingLastPathComponent().path)")
        }
        try coordinationLock.withLock {
            try withCrossProcessCoordination(
                at: lockURL,
                afterLockBeforePathValidation: afterCoordinationLockBeforePathValidation
            ) { coordination in
                switch inspectLockDirectory(coordination) {
                case .absent: return
                case .expected: break
                case .invalid:
                    throw ResourcePreflightError("Apple build lock path contains an unexpected object: \(lockURL.path)")
                }
                guard liveIdentity(ownership.owner.pid) != ownership.owner else {
                    throw ResourcePreflightError("Apple build lock owner is still running: \(lockURL.path)")
                }
                try removePresentLock(
                    at: lockURL,
                    matching: ownership,
                    coordination: coordination,
                    afterValidationBeforeRemoval: afterValidationBeforeRemoval
                )
            }
        }
    }

    private static func removePresentLock(
        at lockURL: URL,
        matching ownership: AppleXcodeBuildLockOwnership,
        coordination: Coordination,
        openedLockDirectory: OpenedLockDirectory? = nil,
        afterValidationBeforeRemoval: () -> Void = {}
    ) throws {
        let lockDirectory = try openedLockDirectory ?? openLockDirectory(coordination)
        defer { if openedLockDirectory == nil { close(lockDirectory.fd) } }
        guard lockURL.path == ownership.path,
              validateLockDirectory(lockDirectory, coordination: coordination),
              try persistedOwnership(lockDirectoryFD: lockDirectory.fd, lockURL: lockURL) == ownership else {
            throw ResourcePreflightError("Apple build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        afterValidationBeforeRemoval()
        guard coordination.validatePathIdentity(),
              validateLockDirectory(lockDirectory, coordination: coordination),
              try persistedOwnership(lockDirectoryFD: lockDirectory.fd, lockURL: lockURL) == ownership,
              coordination.validatePathIdentity() else {
            throw ResourcePreflightError("Apple build lock ownership changed; refusing to remove \(lockURL.path)")
        }
        try removeLockDirectory(lockDirectory, coordination: coordination)
    }

    private static func persistedOwnership(
        lockDirectoryFD: Int32,
        lockURL: URL
    ) throws -> AppleXcodeBuildLockOwnership {
        do {
            let descriptor = openat(lockDirectoryFD, metadataFilename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw ResourcePreflightError("Apple build lock metadata is missing or unsafe: \(lockURL.path)")
            }
            defer { close(descriptor) }
            var openedInfo = stat()
            var namedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  openedInfo.st_mode & S_IFMT == S_IFREG,
                  openedInfo.st_nlink == 1,
                  openedInfo.st_size >= 0,
                  openedInfo.st_size <= maximumMetadataBytes,
                  fstatat(lockDirectoryFD, metadataFilename, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  sameFile(openedInfo, namedInfo) else {
                throw ResourcePreflightError("Apple build lock metadata is missing or unsafe: \(lockURL.path)")
            }
            var data = Data(count: Int(openedInfo.st_size))
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                var offset = 0
                while offset < bytes.count {
                    let amount = read(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if amount > 0 { offset += amount; continue }
                    if amount == -1 && errno == EINTR { continue }
                    return -1
                }
                return offset
            }
            guard count == data.count,
                  fstatat(lockDirectoryFD, metadataFilename, &namedInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  sameFile(openedInfo, namedInfo) else {
                throw ResourcePreflightError("Apple build lock metadata changed while reading: \(lockURL.path)")
            }
            return try JSONDecoder().decode(AppleXcodeBuildLockOwnership.self, from: data)
        } catch {
            throw ResourcePreflightError("Apple build lock metadata is missing or malformed: \(lockURL.path)")
        }
    }

    private static func validatedLockURL(path: String) throws -> URL {
        try configuredLockURL(environment: ["RISHI_APPLE_XCODE_BUILD_LOCK_PATH": path])
    }

    private static func coordinationURL(for lockURL: URL) throws -> URL {
        let name = lockURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ResourcePreflightError("Invalid Apple build lock path: \(lockURL.path)")
        }
        return lockURL.deletingLastPathComponent()
            .appendingPathComponent(".\(name).coordination", isDirectory: false)
    }

    static func coordinationURLForTesting(lockPath: URL) throws -> URL {
        try coordinationURL(for: try validatedLockURL(path: lockPath.path))
    }

    private static func withCrossProcessCoordination<T>(
        at lockURL: URL,
        afterLockBeforePathValidation: () -> Void = {},
        _ operation: (Coordination) throws -> T
    ) throws -> T {
        let parentURL = lockURL.deletingLastPathComponent()
        let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else {
            throw ResourcePreflightError("Could not pin Apple build lock parent directory: \(parentURL.path)")
        }
        defer { close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ResourcePreflightError("Apple build lock parent is unsafe: \(parentURL.path)")
        }
        let coordinationName = ".\(lockURL.lastPathComponent).coordination"
        let descriptor = openat(parentFD, coordinationName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            let coordinationURL = try coordinationURL(for: lockURL)
            throw ResourcePreflightError("Could not open Apple build lock coordination file: \(coordinationURL.path)")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            let coordinationURL = try coordinationURL(for: lockURL)
            throw ResourcePreflightError("Apple build lock coordination file is unsafe: \(coordinationURL.path)")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let coordinationURL = try coordinationURL(for: lockURL)
            throw ResourcePreflightError("Could not secure Apple build lock coordination file: \(coordinationURL.path)")
        }
        while flock(descriptor, LOCK_EX) == -1 {
            guard errno == EINTR else {
                let coordinationURL = try coordinationURL(for: lockURL)
                throw ResourcePreflightError("Could not coordinate Apple build lock: \(coordinationURL.path)")
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        afterLockBeforePathValidation()
        let coordination = Coordination(
            parentFD: parentFD,
            lockName: lockURL.lastPathComponent,
            coordinationName: coordinationName,
            coordinationDevice: info.st_dev,
            coordinationInode: info.st_ino
        )
        guard coordination.validatePathIdentity() else {
            throw ResourcePreflightError("Apple build lock coordination pathname changed: \(lockURL.path)")
        }
        let result = try operation(coordination)
        guard coordination.validatePathIdentity() else {
            throw ResourcePreflightError("Apple build lock coordination pathname changed: \(lockURL.path)")
        }
        return result
    }

    private static func inspectParentDirectory(_ path: String) -> PathInspection {
        var info = stat()
        if lstat(path, &info) == 0 {
            return info.st_mode & S_IFMT == S_IFDIR ? .expected : .invalid
        }
        return errno == ENOENT ? .absent : .invalid
    }

    private static func inspectLockDirectory(_ coordination: Coordination) -> PathInspection {
        var info = stat()
        if fstatat(coordination.parentFD, coordination.lockName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            return info.st_mode & S_IFMT == S_IFDIR ? .expected : .invalid
        }
        return errno == ENOENT ? .absent : .invalid
    }

    private enum PathInspection {
        case absent
        case expected
        case invalid
    }

    private static func openLockDirectory(_ coordination: Coordination) throws -> OpenedLockDirectory {
        let descriptor = openat(
            coordination.parentFD,
            coordination.lockName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw ResourcePreflightError("Could not open Apple build lock directory.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw ResourcePreflightError("Apple build lock path is unsafe.")
        }
        let opened = OpenedLockDirectory(fd: descriptor, device: info.st_dev, inode: info.st_ino)
        guard validateLockDirectory(opened, coordination: coordination) else {
            close(descriptor)
            throw ResourcePreflightError("Apple build lock directory changed while opening.")
        }
        return opened
    }

    private static func validateLockDirectory(
        _ lockDirectory: OpenedLockDirectory,
        coordination: Coordination
    ) -> Bool {
        var info = stat()
        return fstatat(coordination.parentFD, coordination.lockName, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && info.st_dev == lockDirectory.device
            && info.st_ino == lockDirectory.inode
    }

    private static func writeOwnership(_ data: Data, lockDirectoryFD: Int32) throws {
        let temporaryName = ".owner-\(UUID().uuidString).tmp"
        let descriptor = openat(
            lockDirectoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ResourcePreflightError("Could not create Apple build lock metadata.") }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { _ = unlinkat(lockDirectoryFD, temporaryName, 0) }
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let amount = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if amount > 0 { offset += amount; continue }
                if amount == -1 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0,
              renameat(lockDirectoryFD, temporaryName, lockDirectoryFD, metadataFilename) == 0,
              fsync(lockDirectoryFD) == 0 else {
            throw ResourcePreflightError("Could not persist Apple build lock metadata.")
        }
        shouldRemoveTemporary = false
    }

    private static func removeLockDirectory(
        _ lockDirectory: OpenedLockDirectory,
        coordination: Coordination
    ) throws {
        // Darwin has no directory equivalent of pidfd-based, identity-bound
        // unlink. A hostile same-UID process can still rename a pathname in
        // the final syscall interval. Every detectable change fails closed;
        // compliant runners cannot enter this interval because they hold this
        // exact sidecar flock for all acquire/release/reconcile operations.
        guard coordination.validatePathIdentity(),
              validateLockDirectory(lockDirectory, coordination: coordination),
              unlinkat(lockDirectory.fd, metadataFilename, 0) == 0,
              validateLockDirectory(lockDirectory, coordination: coordination),
              coordination.validatePathIdentity(),
              unlinkat(coordination.parentFD, coordination.lockName, AT_REMOVEDIR) == 0 else {
            throw ResourcePreflightError("Could not safely remove Apple build lock directory.")
        }
    }

    private static func removeEmptyLockDirectory(
        _ lockDirectory: OpenedLockDirectory,
        coordination: Coordination
    ) throws {
        guard coordination.validatePathIdentity(),
              validateLockDirectory(lockDirectory, coordination: coordination),
              unlinkat(coordination.parentFD, coordination.lockName, AT_REMOVEDIR) == 0 else {
            throw ResourcePreflightError("Could not safely remove empty Apple build lock directory.")
        }
    }

    private static func sameFile(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private struct OpenedLockDirectory {
        let fd: Int32
        let device: dev_t
        let inode: ino_t
    }

    private struct Coordination {
        let parentFD: Int32
        let lockName: String
        let coordinationName: String
        let coordinationDevice: dev_t
        let coordinationInode: ino_t

        func validatePathIdentity() -> Bool {
            var info = stat()
            return fstatat(parentFD, coordinationName, &info, AT_SYMLINK_NOFOLLOW) == 0
                && info.st_mode & S_IFMT == S_IFREG
                && info.st_dev == coordinationDevice
                && info.st_ino == coordinationInode
                && info.st_uid == geteuid()
                && info.st_nlink == 1
        }
    }

    deinit {
        let shouldRelease = stateLock.withLock { !released && !transferredToRecovery }
        if shouldRelease { try? release() }
    }
}

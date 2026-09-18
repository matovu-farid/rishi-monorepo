import Darwin
import Foundation
import AppKit

/// Exact persisted names shared by live-run production and restrictive
/// recovery decoding. Recovery never infers ownership from near matches.
enum SharedReadingOwnedResourceContract {
    static let disposableSimulatorDeviceTypeIdentifier =
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"

    static func disposableSimulatorName(runID: String) -> String {
        "rishi-e2e-\(runID)"
    }

    static func secretTestRunRelativePath(for role: TestAccountRole) -> String {
        switch role {
        case .owner:
            return "derived/catalyst/Build/Products/owner.xctestrun"
        case .participant:
            return "derived/iPhone17Pro/Build/Products/participant.xctestrun"
        }
    }

    static let secretTestRunRelativePaths: Set<String> = [
        secretTestRunRelativePath(for: .owner),
        secretTestRunRelativePath(for: .participant),
    ]
}

public struct OwnedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let birthTimeSeconds: UInt64
    public let birthTimeMicroseconds: UInt64

    public init(pid: Int32, birthTimeSeconds: UInt64, birthTimeMicroseconds: UInt64) {
        self.pid = pid
        self.birthTimeSeconds = birthTimeSeconds
        self.birthTimeMicroseconds = birthTimeMicroseconds
    }
}

public struct OwnedProcessGroup: Codable, Hashable, Sendable {
    public let processGroupID: Int32
    public let leader: OwnedProcessIdentity

    public init(processGroupID: Int32, leader: OwnedProcessIdentity) {
        self.processGroupID = processGroupID
        self.leader = leader
    }
}

public struct OwnedSimulatorDevice: Codable, Hashable, Sendable {
    public let udid: String?
    public let name: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String

    public init(udid: String?, name: String, deviceTypeIdentifier: String, runtimeIdentifier: String) {
        self.udid = udid
        self.name = name
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
    }
}

public struct PendingCatalystLaunch: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case runner, app }
    public let role: TestAccountRole
    public let kind: Kind
    public let bundleIdentifier: String
    public let baselineIdentities: Set<OwnedProcessIdentity>
    public let registeredIdentity: OwnedProcessIdentity?

    public init(
        role: TestAccountRole,
        kind: Kind,
        bundleIdentifier: String,
        baselineIdentities: Set<OwnedProcessIdentity>,
        registeredIdentity: OwnedProcessIdentity?
    ) {
        self.role = role
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.baselineIdentities = baselineIdentities
        self.registeredIdentity = registeredIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case role, kind, bundleIdentifier, baselineIdentities, registeredIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(TestAccountRole.self, forKey: .role)
        kind = try container.decode(Kind.self, forKey: .kind)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let identities = try container.decode([OwnedProcessIdentity].self, forKey: .baselineIdentities)
        baselineIdentities = Set(identities)
        guard baselineIdentities.count == identities.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Duplicate baseline process identity."))
        }
        registeredIdentity = try container.decodeIfPresent(OwnedProcessIdentity.self, forKey: .registeredIdentity)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(kind, forKey: .kind)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(baselineIdentities.sorted { left, right in
            if left.pid != right.pid { return left.pid < right.pid }
            if left.birthTimeSeconds != right.birthTimeSeconds { return left.birthTimeSeconds < right.birthTimeSeconds }
            return left.birthTimeMicroseconds < right.birthTimeMicroseconds
        }, forKey: .baselineIdentities)
        try container.encodeIfPresent(registeredIdentity, forKey: .registeredIdentity)
    }
}

public protocol OwnedProcessRecording: Sendable {
    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws
    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws
    func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws
    func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws
    func recordCatalystRegisteredIdentity(_ identity: OwnedProcessIdentity, role: TestAccountRole, kind: PendingCatalystLaunch.Kind) throws
}

public enum TestAccountProvisioningOutcome: String, Codable, Sendable {
    case pending
    case recoverable
}

public protocol TestAccountLifecycleRecording: Sendable {
    func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws
    func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws
    func recordVerifiedDeletion(_ email: String) throws
}

public struct AppleXcodeBuildLockOwnership: Codable, Equatable, Sendable {
    public let path: String
    public let token: String
    public let generation: String
    public let owner: OwnedProcessIdentity

    public init(path: String, token: String, generation: String, owner: OwnedProcessIdentity) {
        self.path = path
        self.token = token
        self.generation = generation
        self.owner = owner
    }
}

public struct NoopTestAccountLifecycleRecorder: TestAccountLifecycleRecording {
    public init() {}
    public func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws {}
    public func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {}
    public func recordVerifiedDeletion(_ email: String) throws {}
}

public struct NoopOwnedProcessRecorder: OwnedProcessRecording {
    public init() {}
    public func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {}
    public func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {}
    public func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {}
    public func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {}
    public func recordCatalystRegisteredIdentity(_ identity: OwnedProcessIdentity, role: TestAccountRole, kind: PendingCatalystLaunch.Kind) throws {}
}

public enum SharedReadingRecoveryJournalError: Error, Equatable {
    case malformedArtifact
    case runIDMismatch
    case missingRecordedAccount
    case missingRecordedProcessGroup
    case missingRecordedProcess
    case missingRecordedSimulatorDevice
    case missingCatalystLaunchIntent
    case ambiguousCatalystLaunchIntent
    case conflictingCatalystLaunchIntent
    case catalystLaunchAlreadyRegistered
    case missingRecordedSecretArtifact
    case missingRecordedBuildLock
    case conflictingBuildLock
    case invalidRealizedSimulatorDevice
    case invalidSecretArtifactPath
    case unsafeRecoveryArtifact
    case cleanupIncomplete
    case journalRemovalFailed
    case permissionsNotApplied
    case journalFinalized
}

public final class SharedReadingRecoveryJournal: @unchecked Sendable, TestAccountLifecycleRecording, OwnedProcessRecording {
    public let url: URL

    private static let inProcessInterprocessLock = NSLock()
    private static let maximumEncodedJournalBytes = 1_048_576
    private static let maximumRecoveryTreeDepth = 64
    private static let maximumRecoveryTreeEntries = 500_000
    private static let maximumRecoveryTreeBytes: UInt64 = 100 * 1_024 * 1_024 * 1_024
    private let lock = NSLock()
    private let rootDirectoryFD: Int32
    private let runDirectoryFD: Int32
    private let runDirectoryName: String
    private let journalFilename: String
    private let runDirectoryDevice: dev_t
    private let runDirectoryInode: ino_t
    private var state: RecoveryState
    private var finalized = false

    /// Owns creation of the run directory containing `url`.
    ///
    /// Callers may create the parent root, but must not precreate this exact run directory.
    public convenience init(url: URL, runID: String) throws {
        try self.init(url: url, runID: runID, beforeInitialDirectoryLock: nil)
    }

#if DEBUG
    convenience init(
        url: URL,
        runID: String,
        beforeInitialDirectoryLockForTesting: @escaping () -> Void
    ) throws {
        try self.init(url: url, runID: runID, beforeInitialDirectoryLock: beforeInitialDirectoryLockForTesting)
    }
#endif

    private init(
        url: URL,
        runID: String,
        beforeInitialDirectoryLock: (() -> Void)?
    ) throws {
        let storage = try Self.openStorage(for: url, runID: runID)
        do {
            beforeInitialDirectoryLock?()
            let (decoded, finalized) = try Self.withInterprocessLock(storage.runDirectoryFD) {
                try Self.validateRunDirectory(storage)
                let hasJournal = try Self.fileKind(
                    at: storage.journalFilename,
                    directoryFD: storage.runDirectoryFD
                ) != nil
                if hasJournal {
                    return (
                        try Self.loadState(
                            from: storage.runDirectoryFD,
                            filename: storage.journalFilename,
                            runID: runID
                        ),
                        false
                    )
                }
                return (RecoveryState(runID: runID), true)
            }
            self.url = url
            self.rootDirectoryFD = storage.rootDirectoryFD
            self.runDirectoryFD = storage.runDirectoryFD
            self.runDirectoryName = storage.runDirectoryName
            self.journalFilename = storage.journalFilename
            self.runDirectoryDevice = storage.runDirectoryDevice
            self.runDirectoryInode = storage.runDirectoryInode
            self.state = decoded
            self.finalized = finalized
        } catch {
            close(storage.runDirectoryFD)
            close(storage.rootDirectoryFD)
            throw error
        }
    }

    deinit {
        close(runDirectoryFD)
        close(rootDirectoryFD)
    }

    public func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws {
        try mutate { state in
            state.accounts.removeAll { $0.email == email }
            state.accounts.append(RecordedAccount(email: email, role: role, outcome: .pending))
        }
    }

    public func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {
        try mutate { state in
            guard let index = state.accounts.firstIndex(where: { $0.email == email }) else {
                throw SharedReadingRecoveryJournalError.missingRecordedAccount
            }
            state.accounts[index].outcome = outcome
        }
    }

    public func recordVerifiedDeletion(_ email: String) throws {
        try mutate { state in
            guard state.accounts.contains(where: { $0.email == email }) else {
                throw SharedReadingRecoveryJournalError.missingRecordedAccount
            }
            state.accounts.removeAll { $0.email == email }
        }
    }

    public func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {
        try mutate { $0.processGroups.insert(group) }
    }

    public func recordVerifiedProcessGroupAbsence(_ group: OwnedProcessGroup) throws {
        try mutate { state in
            guard state.processGroups.remove(group) != nil else {
                throw SharedReadingRecoveryJournalError.missingRecordedProcessGroup
            }
        }
    }

    public func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {
        try mutate { $0.processes.insert(identity) }
    }

    public func recordVerifiedProcessAbsence(_ identity: OwnedProcessIdentity) throws {
        try mutate { state in
            guard state.processes.remove(identity) != nil else {
                throw SharedReadingRecoveryJournalError.missingRecordedProcess
            }
        }
    }

    public func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {
        try mutate { $0.simulatorDevices.insert(device) }
    }

    public func recordRealizedSimulatorDevice(
        _ realized: OwnedSimulatorDevice,
        replacingIntent intent: OwnedSimulatorDevice
    ) throws {
        guard intent.udid == nil,
              realized.udid != nil,
              intent.name == realized.name,
              intent.deviceTypeIdentifier == realized.deviceTypeIdentifier,
              intent.runtimeIdentifier == realized.runtimeIdentifier else {
            throw SharedReadingRecoveryJournalError.invalidRealizedSimulatorDevice
        }
        try mutate { state in
            guard state.simulatorDevices.remove(intent) != nil else {
                throw SharedReadingRecoveryJournalError.missingRecordedSimulatorDevice
            }
            state.simulatorDevices.insert(realized)
        }
    }

    public func recordVerifiedSimulatorDeletion(_ device: OwnedSimulatorDevice) throws {
        try mutate { state in
            guard state.simulatorDevices.remove(device) != nil else {
                throw SharedReadingRecoveryJournalError.missingRecordedSimulatorDevice
            }
        }
    }

    public func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {
        try mutate { state in
            let matching = state.pendingCatalystLaunches.filter {
                $0.role == intent.role && $0.kind == intent.kind
            }
            guard matching.count <= 1 else {
                throw SharedReadingRecoveryJournalError.ambiguousCatalystLaunchIntent
            }
            if let existing = matching.first {
                guard existing == intent else {
                    throw SharedReadingRecoveryJournalError.conflictingCatalystLaunchIntent
                }
                return
            }
            state.pendingCatalystLaunches.insert(intent)
        }
    }

    public func recordCatalystRegisteredIdentity(
        _ identity: OwnedProcessIdentity,
        role: TestAccountRole,
        kind: PendingCatalystLaunch.Kind
    ) throws {
        try mutate { state in
            let matching = state.pendingCatalystLaunches.filter {
                $0.role == role && $0.kind == kind
            }
            guard matching.count == 1 else {
                if matching.isEmpty {
                    throw SharedReadingRecoveryJournalError.missingCatalystLaunchIntent
                }
                throw SharedReadingRecoveryJournalError.ambiguousCatalystLaunchIntent
            }
            guard let intent = matching.first else {
                throw SharedReadingRecoveryJournalError.missingCatalystLaunchIntent
            }
            guard intent.registeredIdentity == nil else {
                throw SharedReadingRecoveryJournalError.catalystLaunchAlreadyRegistered
            }
            state.pendingCatalystLaunches.remove(intent)
            state.pendingCatalystLaunches.insert(PendingCatalystLaunch(
                role: intent.role,
                kind: intent.kind,
                bundleIdentifier: intent.bundleIdentifier,
                baselineIdentities: intent.baselineIdentities,
                registeredIdentity: identity
            ))
        }
    }

    public func recordVerifiedCatalystLaunchAbsence(_ launch: PendingCatalystLaunch) throws {
        try mutate { state in
            guard state.pendingCatalystLaunches.remove(launch) != nil else {
                throw SharedReadingRecoveryJournalError.missingCatalystLaunchIntent
            }
        }
    }

    public func recordSecretArtifact(relativePath: String) throws {
        guard Self.isSafeRelativePath(relativePath) else {
            throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
        }
        try mutate { $0.secretArtifactRelativePaths.insert(relativePath) }
    }

    public func recordVerifiedSecretArtifactDeletion(relativePath: String) throws {
        try mutate { state in
            guard state.secretArtifactRelativePaths.remove(relativePath) != nil else {
                throw SharedReadingRecoveryJournalError.missingRecordedSecretArtifact
            }
        }
    }

    public func recordBuildLock(_ ownership: AppleXcodeBuildLockOwnership) throws {
        try mutate { state in
            if let recorded = state.buildLock {
                guard recorded == ownership else {
                    throw SharedReadingRecoveryJournalError.conflictingBuildLock
                }
                return
            }
            state.buildLock = ownership
        }
    }

    public func recordVerifiedBuildLockRelease(_ ownership: AppleXcodeBuildLockOwnership) throws {
        try mutate { state in
            guard state.buildLock == ownership else {
                throw SharedReadingRecoveryJournalError.missingRecordedBuildLock
            }
            state.buildLock = nil
        }
    }

    public func finalizeAfterSuccessfulCleanup() throws {
        try lock.withLock {
            guard !finalized else { throw SharedReadingRecoveryJournalError.journalFinalized }
            try Self.withInterprocessLock(runDirectoryFD) {
                try validateRunDirectory()
                let current = try Self.loadState(from: runDirectoryFD, filename: journalFilename, runID: state.runID)
                guard current.isEmpty else {
                    throw SharedReadingRecoveryJournalError.cleanupIncomplete
                }
                guard let kind = try Self.fileKind(at: journalFilename, directoryFD: runDirectoryFD) else {
                    state = current
                    finalized = true
                    return
                }
                guard kind == S_IFREG else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                guard unlinkat(runDirectoryFD, journalFilename, 0) == 0 else {
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
                guard fsync(runDirectoryFD) == 0 else {
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
                state = current
                finalized = true
            }
        }
    }

    func finalizeAndRemoveEmptyRunDirectory() throws {
        try finalizeAfterSuccessfulCleanup()
        try lock.withLock {
            try Self.withInterprocessLock(rootDirectoryFD) {
                try validateRunDirectory()
                let entries = try Self.withDirectoryEntries(runDirectoryFD) { $0 }
                guard entries.isEmpty else {
                    throw SharedReadingRecoveryJournalError.cleanupIncomplete
                }
                guard unlinkat(rootDirectoryFD, runDirectoryName, AT_REMOVEDIR) == 0,
                      fsync(rootDirectoryFD) == 0 else {
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
            }
        }
    }

    public static func unresolvedArtifact(in root: URL) throws -> URL? {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if rootFD < 0 {
            if errno == ENOENT { return nil }
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        defer { close(rootFD) }
        return try Self.withDirectoryEntries(rootFD) { names in
            for name in names where name.hasPrefix("rishi-shared-reading-") {
                guard try fileKind(at: name, directoryFD: rootFD) == S_IFDIR else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                let childFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
                defer { close(childFD) }
                for candidate in ["recovery.json", "manifest.json"] {
                    guard let kind = try fileKind(at: candidate, directoryFD: childFD) else { continue }
                    guard kind == S_IFREG else {
                        throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                    }
                    return root.appendingPathComponent(name).appendingPathComponent(candidate)
                }
            }
            return nil
        }
    }

    private func mutate(_ update: (inout RecoveryState) throws -> Void) throws {
        try lock.withLock {
            guard !finalized else { throw SharedReadingRecoveryJournalError.journalFinalized }
            try Self.withInterprocessLock(runDirectoryFD) {
                try validateRunDirectory()
                let journalExists = try Self.fileKind(at: journalFilename, directoryFD: runDirectoryFD) != nil
                guard journalExists else {
                    finalized = true
                    throw SharedReadingRecoveryJournalError.journalFinalized
                }
                var candidate = try Self.loadState(from: runDirectoryFD, filename: journalFilename, runID: state.runID)
                try update(&candidate)
                try Self.writeAtomically(candidate, to: runDirectoryFD, filename: journalFilename)
                state = candidate
            }
        }
    }

    func descriptorFlagsForTesting() -> [Int32] {
        [
            fcntl(rootDirectoryFD, F_GETFD),
            fcntl(runDirectoryFD, F_GETFD),
        ]
    }

    private func validateRunDirectory() throws {
        try Self.validateRunDirectory(Storage(
            rootDirectoryFD: rootDirectoryFD,
            runDirectoryFD: runDirectoryFD,
            runDirectoryName: runDirectoryName,
            journalFilename: journalFilename,
            runDirectoryDevice: runDirectoryDevice,
            runDirectoryInode: runDirectoryInode
        ))
    }

    // Data.write(options: [.atomic]) cannot target an already-open directory descriptor.
    // This is its race-safe equivalent: fchmod + fsync a no-follow temp file, then renameat.
    private static func writeAtomically(_ state: RecoveryState, to directoryFD: Int32, filename: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try writeDataAtomically(
            data,
            to: directoryFD,
            filename: filename,
            permissions: mode_t(S_IRUSR | S_IWUSR)
        )
    }

    private static func writeDataAtomically(
        _ data: Data,
        to directoryFD: Int32,
        filename: String,
        permissions: mode_t
    ) throws {
        if let existing = try fileKind(at: filename, directoryFD: directoryFD), existing != S_IFREG {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let fileFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.permissionsNotApplied }
        var shouldRemoveTemporary = true
        defer {
            close(fileFD)
            if shouldRemoveTemporary { _ = unlinkat(directoryFD, temporaryName, 0) }
        }
        guard fchmod(fileFD, permissions) == 0 else {
            throw SharedReadingRecoveryJournalError.permissionsNotApplied
        }
        try writeAll(data, to: fileFD)
        guard fsync(fileFD) == 0 else { throw SharedReadingRecoveryJournalError.permissionsNotApplied }
        guard renameat(directoryFD, temporaryName, directoryFD, filename) == 0 else {
            throw SharedReadingRecoveryJournalError.permissionsNotApplied
        }
        shouldRemoveTemporary = false
        guard fsync(directoryFD) == 0 else { throw SharedReadingRecoveryJournalError.permissionsNotApplied }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }

    private static func fileKind(at name: String, directoryFD: Int32) throws -> mode_t? {
        var details = stat()
        guard fstatat(directoryFD, name, &details, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        return details.st_mode & S_IFMT
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(fileDescriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SharedReadingRecoveryJournalError.permissionsNotApplied
                }
                offset += Int(written)
            }
        }
    }

    private static func readAll(from fileDescriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
            guard Int(count) <= maximumBytes - result.count else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    private static func loadState(from directoryFD: Int32, filename: String, runID: String) throws -> RecoveryState {
        guard let kind = try fileKind(at: filename, directoryFD: directoryFD) else {
            return RecoveryState(runID: runID)
        }
        guard kind == S_IFREG else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        let fileFD = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        defer { close(fileFD) }
        var details = stat()
        guard fstat(fileFD, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        guard details.st_size >= 0, details.st_size <= off_t(maximumEncodedJournalBytes) else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
        do {
            let decoded = try JSONDecoder().decode(
                RecoveryState.self,
                from: try readAll(from: fileFD, maximumBytes: maximumEncodedJournalBytes)
            )
            guard decoded.runID == runID else { throw SharedReadingRecoveryJournalError.runIDMismatch }
            return decoded
        } catch let error as SharedReadingRecoveryJournalError {
            throw error
        } catch {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    private static func withInterprocessLock<T>(_ directoryFD: Int32, _ operation: () throws -> T) throws -> T {
        try inProcessInterprocessLock.withLock {
            guard flock(directoryFD, LOCK_EX) == 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { _ = flock(directoryFD, LOCK_UN) }
            return try operation()
        }
    }

    private static func withDirectoryEntries<T>(
        _ directoryFD: Int32,
        maximumCount: Int? = nil,
        _ operation: ([String]) throws -> T
    ) throws -> T {
        let duplicateFD = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicateFD >= 0, let directory = fdopendir(duplicateFD) else {
            if duplicateFD >= 0 { close(duplicateFD) }
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." {
                if let maximumCount, names.count >= maximumCount {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                names.append(name)
            }
        }
        return try operation(names.sorted())
    }

    private static func openStorage(for url: URL, runID: String) throws -> Storage {
        let runDirectory = url.deletingLastPathComponent()
        let rootDirectory = runDirectory.deletingLastPathComponent()
        let runName = runDirectory.lastPathComponent
        let filename = url.lastPathComponent
        guard !runName.isEmpty, runName != ".", !filename.isEmpty, filename != "." else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let rootFD = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        do {
            return try Self.withInterprocessLock(rootFD) {
                let didCreateRunDirectory: Bool
                if mkdirat(rootFD, runName, mode_t(S_IRWXU)) == 0 {
                    didCreateRunDirectory = true
                } else if errno == EEXIST {
                    didCreateRunDirectory = false
                } else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                let runFD = openat(rootFD, runName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard runFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
                do {
                    var details = stat()
                    guard fstat(runFD, &details) == 0, details.st_mode & S_IFMT == S_IFDIR else {
                        throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                    }
                    if didCreateRunDirectory {
                        try Self.withDirectoryLockAlreadySerialized(runFD) {
                            try Self.writeAtomically(
                                RecoveryState(runID: runID),
                                to: runFD,
                                filename: filename
                            )
                        }
                    }
                    return Storage(
                        rootDirectoryFD: rootFD,
                        runDirectoryFD: runFD,
                        runDirectoryName: runName,
                        journalFilename: filename,
                        runDirectoryDevice: details.st_dev,
                        runDirectoryInode: details.st_ino
                    )
                } catch {
                    close(runFD)
                    throw error
                }
            }
        } catch {
            close(rootFD)
            throw error
        }
    }

    private static func withDirectoryLockAlreadySerialized<T>(
        _ directoryFD: Int32,
        _ operation: () throws -> T
    ) throws -> T {
        guard flock(directoryFD, LOCK_EX) == 0 else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        defer { _ = flock(directoryFD, LOCK_UN) }
        return try operation()
    }

    private static func validateRunDirectory(_ storage: Storage) throws {
        var details = stat()
        guard fstatat(storage.rootDirectoryFD, storage.runDirectoryName, &details, AT_SYMLINK_NOFOLLOW) == 0,
              details.st_mode & S_IFMT == S_IFDIR,
              details.st_dev == storage.runDirectoryDevice,
              details.st_ino == storage.runDirectoryInode else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
    }

    private struct Storage {
        let rootDirectoryFD: Int32
        let runDirectoryFD: Int32
        let runDirectoryName: String
        let journalFilename: String
        let runDirectoryDevice: dev_t
        let runDirectoryInode: ino_t
    }
}

struct RecoveryArtifactValidation: Sendable {
    let emailIsInConfiguredNamespace: @Sendable (String) -> Bool
    let allowedRuntimeIdentifiers: Set<String>
    let runnerBundleIdentifier: String
    let appBundleIdentifier: String
}

struct RecoveryArtifact: Sendable {
    let url: URL
    let runID: String
    let accounts: [RecordedAccount]
    let processGroups: Set<OwnedProcessGroup>
    let processes: Set<OwnedProcessIdentity>
    let simulatorDevices: Set<OwnedSimulatorDevice>
    let pendingCatalystLaunches: Set<PendingCatalystLaunch>
    let secretArtifactURLs: Set<URL>
    let buildLock: AppleXcodeBuildLockOwnership?
    let isLegacy: Bool
}

struct RecoveryOperations: Sendable {
    let recoverProcessGroup: @Sendable (OwnedProcessGroup) async throws -> Void
    let recoverProcess: @Sendable (OwnedProcessIdentity) async throws -> Void
    let currentCatalystIdentities: @Sendable (String) throws -> Set<OwnedProcessIdentity>
    let recoverSimulator: @Sendable (OwnedSimulatorDevice) async throws -> Void
    let removeSecretArtifact: @Sendable (URL) throws -> Void
    let recoverAccount: @Sendable (RecordedAccount) async throws -> Void
    let exactRunIDProcessIsVisible: @Sendable (String) throws -> Bool
    let configuredBuildLockExists: @Sendable (URL) throws -> Bool
    let finalizeArtifactAndBuildLock: @Sendable (URL, AppleXcodeBuildLockOwnership?) throws -> Void
}

private struct RecoveryTreeBudget {
    var entries = 0
    var bytes: UInt64 = 0
}

private struct RecoveryTreeNode {
    let name: String
    let device: dev_t
    let inode: ino_t
    let type: mode_t
    let size: off_t
    let children: [RecoveryTreeNode]
}

private struct RecoveryCombinedError: Error, LocalizedError {
    let failureCount: Int
    var errorDescription: String? {
        "Shared-reading recovery could not prove complete cleanup (\(failureCount) failure(s))."
    }
}

extension SharedReadingRecoveryJournal {
    public static func recover(
        at artifactURL: URL,
        temporaryRoot: URL,
        configuredBuildLockURL: URL,
        accountClient: TestAccountClient
    ) async throws {
        let claimedRuntimeIdentifiers = try claimedSimulatorRuntimeIdentifiers(
            at: artifactURL,
            temporaryRoot: temporaryRoot
        )
        let validation = RecoveryArtifactValidation(
            emailIsInConfiguredNamespace: accountClient.isGeneratedRecoveryEmail,
            allowedRuntimeIdentifiers: claimedRuntimeIdentifiers,
            runnerBundleIdentifier: "org.fidexa.rishiUITests",
            appBundleIdentifier: "org.fidexa.rishi"
        )
        let artifact = try decodeRecoveryArtifact(
            at: artifactURL,
            temporaryRoot: temporaryRoot,
            configuredBuildLockURL: configuredBuildLockURL,
            validation: validation
        )
        if !artifact.simulatorDevices.isEmpty {
            let configuredRuntimeIdentifiers = try await productionSimulatorRuntimeIdentifiers()
            guard artifact.simulatorDevices.allSatisfy({
                configuredRuntimeIdentifiers.contains($0.runtimeIdentifier)
            }) else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
        }
        let operations = RecoveryOperations(
            recoverProcessGroup: { group in
                try await recoverProcessGroups(
                    [group],
                    liveIdentity: ProcessIdentityReader.identity(for:),
                    members: OwnedProcessGroupInspector.members(in:),
                    processGroup: OwnedProcessGroupInspector.processGroup(of:),
                    signal: { pid, signal in _ = Darwin.kill(pid, signal) },
                    sleep: { duration in try await Task.sleep(for: duration) }
                )
            },
            recoverProcess: { process in
                try await recoverProcesses(
                    [process],
                    liveIdentity: ProcessIdentityReader.identity(for:),
                    signal: { pid, signal in _ = Darwin.kill(pid, signal) },
                    sleep: { duration in try await Task.sleep(for: duration) }
                )
            },
            currentCatalystIdentities: productionCatalystIdentities(bundleIdentifier:),
            recoverSimulator: { simulator in try await recoverProductionSimulator(simulator) },
            removeSecretArtifact: { url in
                try removeProductionSecretArtifact(
                    at: url,
                    runRoot: artifact.url.deletingLastPathComponent()
                )
            },
            recoverAccount: { account in
                try await accountClient.deleteProvisionedAccount(email: account.email)
            },
            exactRunIDProcessIsVisible: productionExactRunIDProcessIsVisible(_:),
            configuredBuildLockExists: productionPathExists(_:),
            finalizeArtifactAndBuildLock: { url, buildLock in
                try finalizeProductionArtifactAndBuildLock(
                    at: url,
                    temporaryRoot: temporaryRoot,
                    buildLock: buildLock
                )
            }
        )
        try await orchestrateRecovery(
            artifact,
            configuredBuildLockURL: configuredBuildLockURL,
            operations: operations
        )
    }

    internal static func decodeRecoveryArtifact(
        at artifactURL: URL,
        temporaryRoot: URL,
        configuredBuildLockURL: URL,
        validation: RecoveryArtifactValidation
    ) throws -> RecoveryArtifact {
        do {
            let data = try readRecoveryArtifactData(at: artifactURL, temporaryRoot: temporaryRoot)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
            let keys = Set(object.keys)
            let journalRequired: Set<String> = [
                "runID", "accounts", "processGroups", "processes", "simulatorDevices",
                "pendingCatalystLaunches", "secretArtifactRelativePaths",
            ]
            let journalAllowed = journalRequired.union(["buildLock"])
            let rendezvousKeys: Set<String> = [
                "runID", "fixture", "ownerEmail", "participantEmail",
                "ownerDestination", "participantDestination", "rendezvousPath",
            ]
            let persistedKeys: Set<String> = [
                "runID", "owner", "participant", "fixture", "manifestPath",
                "ownerDestination", "participantDestination", "rendezvousPath",
            ]

            let artifact: RecoveryArtifact
            if journalRequired.isSubset(of: keys), keys.isSubset(of: journalAllowed) {
                try validateJournalJSONShape(object)
                let state = try JSONDecoder().decode(RecoveryState.self, from: data)
                artifact = try normalizedJournal(
                    state,
                    at: artifactURL,
                    configuredBuildLockURL: configuredBuildLockURL,
                    validation: validation
                )
            } else if keys == rendezvousKeys {
                try validateFixtureShape(object["fixture"])
                let manifest = try JSONDecoder().decode(RendezvousManifest.self, from: data)
                artifact = try normalizedLegacy(
                    runID: manifest.runID,
                    accounts: [
                        RecordedAccount(email: manifest.ownerEmail, role: .owner, outcome: .recoverable),
                        RecordedAccount(email: manifest.participantEmail, role: .participant, outcome: .recoverable),
                    ],
                    at: artifactURL,
                    validation: validation
                )
            } else if keys == persistedKeys {
                try validateFixtureShape(object["fixture"])
                try validatePersistedAccountShape(object["owner"], role: .owner)
                try validatePersistedAccountShape(object["participant"], role: .participant)
                let manifest = try JSONDecoder().decode(PersistedHostRecoveryManifest.self, from: data)
                artifact = try normalizedLegacy(
                    runID: manifest.runID,
                    accounts: [
                        RecordedAccount(email: manifest.owner.email, role: manifest.owner.role, outcome: .recoverable),
                        RecordedAccount(email: manifest.participant.email, role: manifest.participant.role, outcome: .recoverable),
                    ],
                    at: artifactURL,
                    validation: validation
                )
            } else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
            try validateArtifactLocation(artifact, temporaryRoot: temporaryRoot)
            return artifact
        } catch let error as SharedReadingRecoveryJournalError {
            throw error
        } catch {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    internal static func recover(
        at artifactURL: URL,
        temporaryRoot: URL,
        configuredBuildLockURL: URL,
        validation: RecoveryArtifactValidation,
        operations: RecoveryOperations
    ) async throws {
        let artifact = try decodeRecoveryArtifact(
            at: artifactURL,
            temporaryRoot: temporaryRoot,
            configuredBuildLockURL: configuredBuildLockURL,
            validation: validation
        )

        try await orchestrateRecovery(
            artifact,
            configuredBuildLockURL: configuredBuildLockURL,
            operations: operations
        )
    }

    private static func orchestrateRecovery(
        _ artifact: RecoveryArtifact,
        configuredBuildLockURL: URL,
        operations: RecoveryOperations
    ) async throws {
        var failures = 0
        if artifact.isLegacy {
            do {
                if try operations.exactRunIDProcessIsVisible(artifact.runID) { failures += 1 }
            } catch { failures += 1 }
            do {
                if try operations.configuredBuildLockExists(configuredBuildLockURL) { failures += 1 }
            } catch { failures += 1 }
        } else {
            for group in artifact.processGroups.sorted(by: RecoveryState.processGroupsInOrder) {
                do { try await operations.recoverProcessGroup(group) }
                catch { failures += 1 }
            }
            var identities = artifact.processes
            identities.formUnion(artifact.pendingCatalystLaunches.compactMap(\.registeredIdentity))
            for process in identities.sorted(by: RecoveryState.processesInOrder) {
                do { try await operations.recoverProcess(process) }
                catch { failures += 1 }
            }
            for launch in artifact.pendingCatalystLaunches where launch.registeredIdentity == nil {
                do {
                    let current = try operations.currentCatalystIdentities(launch.bundleIdentifier)
                    guard current.isSubset(of: launch.baselineIdentities) else {
                        throw SharedReadingRecoveryJournalError.cleanupIncomplete
                    }
                } catch { failures += 1 }
            }
        }
        guard failures == 0 else { throw RecoveryCombinedError(failureCount: failures) }

        if !artifact.isLegacy {
            for simulator in artifact.simulatorDevices.sorted(by: RecoveryState.simulatorDevicesInOrder) {
                do { try await operations.recoverSimulator(simulator) }
                catch { failures += 1 }
            }
            for secretURL in artifact.secretArtifactURLs.sorted(by: { $0.path < $1.path }) {
                do { try operations.removeSecretArtifact(secretURL) }
                catch { failures += 1 }
            }
        }
        guard failures == 0 else { throw RecoveryCombinedError(failureCount: failures) }

        for account in artifact.accounts.sorted(by: RecoveryState.accountsInOrder) {
            do { try await operations.recoverAccount(account) }
            catch { failures += 1 }
        }
        guard failures == 0 else { throw RecoveryCombinedError(failureCount: failures) }

        do { try operations.finalizeArtifactAndBuildLock(artifact.url, artifact.buildLock) }
        catch { failures += 1 }
        guard failures == 0 else { throw RecoveryCombinedError(failureCount: failures) }
    }

    private static func productionCatalystIdentities(
        bundleIdentifier: String
    ) throws -> Set<OwnedProcessIdentity> {
        var identities: Set<OwnedProcessIdentity> = []
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            let pid = application.processIdentifier
            guard let identity = ProcessIdentityReader.identity(for: pid),
                  ProcessIdentityReader.identity(for: pid) == identity else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
            identities.insert(identity)
        }
        return identities
    }

    private static func claimedSimulatorRuntimeIdentifiers(
        at artifactURL: URL,
        temporaryRoot: URL
    ) throws -> Set<String> {
        let data = try readRecoveryArtifactData(at: artifactURL, temporaryRoot: temporaryRoot)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["simulatorDevices"] as? [[String: Any]] else {
            return []
        }
        return Set(try devices.map { device in
            guard let runtime = device["runtimeIdentifier"] as? String else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
            return runtime
        })
    }

    static func productionExactRunIDProcessIsVisible(_ runID: String) throws -> Bool {
        // Legacy artifacts contain no stable process identity. NSWorkspace only
        // enumerates applications, and its display name cannot prove absence of
        // CLI, xcodebuild, or XCTest processes. Darwin offers no safe exact-run
        // discovery primitive without forbidden argv/environment inspection.
        _ = runID
        throw SharedReadingRecoveryJournalError.cleanupIncomplete
    }

    private static func productionPathExists(_ url: URL) throws -> Bool {
        var details = stat()
        if lstat(url.path, &details) == 0 { return true }
        if errno == ENOENT { return false }
        throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
    }

    private static func productionSimulatorRuntimeIdentifiers() async throws -> Set<String> {
        Set(try await productionSimulatorInventory().map(\.runtimeIdentifier))
    }

    private static func recoverProductionSimulator(_ recorded: OwnedSimulatorDevice) async throws {
        let initial = try await productionSimulatorInventory()
        let exactMatches = initial.filter {
            $0.name == recorded.name
                && $0.deviceTypeIdentifier == recorded.deviceTypeIdentifier
                && $0.runtimeIdentifier == recorded.runtimeIdentifier
        }
        let target: ProductionSimulatorDevice
        if let udid = recorded.udid {
            if let exact = exactMatches.first(where: { $0.udid == udid }) {
                target = exact
            } else if initial.contains(where: { $0.udid == udid || $0.name == recorded.name }) {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            } else {
                return
            }
        } else {
            guard exactMatches.count <= 1 else { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
            guard let exact = exactMatches.first else { return }
            target = exact
        }

        let shutdown = try await runSimctl(["shutdown", target.udid])
        if !shutdown.succeeded {
            let diagnostic = shutdown.stderr.lowercased()
            guard diagnostic.contains("current state: shutdown") || diagnostic.contains("already shutdown") else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
        }
        guard try await runSimctl(["delete", target.udid]).succeeded else {
            throw SharedReadingRecoveryJournalError.cleanupIncomplete
        }
        for _ in 0..<6 {
            let remaining = try await productionSimulatorInventory()
            if !remaining.contains(where: { $0.udid == target.udid || $0.name == recorded.name }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SharedReadingRecoveryJournalError.cleanupIncomplete
    }

    private static func productionSimulatorInventory() async throws -> [ProductionSimulatorDevice] {
        let result = try await runSimctl(["list", "devices", "--json"])
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else {
            throw SharedReadingRecoveryJournalError.cleanupIncomplete
        }
        do {
            let decoded = try JSONDecoder().decode(ProductionSimulatorInventory.self, from: data)
            return decoded.devices.flatMap { runtime, devices in
                devices.map {
                    ProductionSimulatorDevice(
                        udid: $0.udid,
                        name: $0.name,
                        deviceTypeIdentifier: $0.deviceTypeIdentifier,
                        runtimeIdentifier: runtime
                    )
                }
            }
        } catch {
            throw SharedReadingRecoveryJournalError.cleanupIncomplete
        }
    }

    private static func runSimctl(_ arguments: [String]) async throws -> ProcessResult {
        try await FoundationProcessRunner().run(ProcessRequest(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl"] + arguments
        ))
    }

    internal static func removeProductionSecretArtifact(at url: URL, runRoot: URL) throws {
        let root = runRoot.standardizedFileURL
        let artifact = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard runRoot.path == root.path,
              url.path == artifact.path,
              artifact.path.hasPrefix(prefix) else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let relativePath = String(artifact.path.dropFirst(prefix.count))
        guard SharedReadingOwnedResourceContract.secretTestRunRelativePaths.contains(relativePath) else {
            throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1, let filename = components.last else {
            throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
        }

        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        var directoryFDs = [rootFD]
        defer { directoryFDs.reversed().forEach { close($0) } }

        var reachedArtifactParent = true
        for component in components.dropLast() {
            let childFD = openat(
                directoryFDs.last!, component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if childFD < 0, errno == ENOENT {
                reachedArtifactParent = false
                break
            }
            guard childFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            directoryFDs.append(childFD)
        }

        if reachedArtifactParent {
            let parentFD = directoryFDs.last!
            if let kind = try fileKind(at: filename, directoryFD: parentFD) {
                guard kind == S_IFREG else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
                let artifactFD = openat(parentFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard artifactFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
                defer { close(artifactFD) }
                var opened = stat()
                var named = stat()
                guard fstat(artifactFD, &opened) == 0,
                      fstatat(parentFD, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_mode & S_IFMT == S_IFREG,
                      opened.st_dev == named.st_dev,
                      opened.st_ino == named.st_ino,
                      unlinkat(parentFD, filename, 0) == 0,
                      fsync(parentFD) == 0,
                      try fileKind(at: filename, directoryFD: parentFD) == nil else {
                    throw SharedReadingRecoveryJournalError.cleanupIncomplete
                }
            }
        }

        let directoryNames = Array(components.dropLast())
        guard directoryFDs.count > 1 else { return }
        for index in stride(from: directoryFDs.count - 1, through: 1, by: -1) {
            let parent = directoryFDs[index - 1]
            let childName = directoryNames[index - 1]
            var openedDirectory = stat()
            var namedDirectory = stat()
            guard fstat(directoryFDs[index], &openedDirectory) == 0,
                  fstatat(parent, childName, &namedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                  namedDirectory.st_mode & S_IFMT == S_IFDIR,
                  openedDirectory.st_dev == namedDirectory.st_dev,
                  openedDirectory.st_ino == namedDirectory.st_ino else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            if unlinkat(parent, childName, AT_REMOVEDIR) == 0 {
                guard fsync(parent) == 0 else {
                    throw SharedReadingRecoveryJournalError.cleanupIncomplete
                }
            } else if errno != ENOTEMPTY && errno != EEXIST {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
        }
    }

    private static func snapshotOwnedRecoveryTree(
        named name: String,
        parentFD: Int32,
        runDevice: dev_t,
        depth: Int,
        budget: inout RecoveryTreeBudget
    ) throws -> RecoveryTreeNode {
        guard depth <= maximumRecoveryTreeDepth,
              budget.entries < maximumRecoveryTreeEntries else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        budget.entries += 1

        var named = stat()
        guard fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == runDevice else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let type = named.st_mode & S_IFMT
        switch type {
        case S_IFDIR:
            let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { close(directoryFD) }
            var opened = stat()
            guard fstat(directoryFD, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFDIR,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            let children = try withDirectoryEntries(
                directoryFD,
                maximumCount: maximumRecoveryTreeEntries - budget.entries
            ) { names in
                try names.map { child in
                    try snapshotOwnedRecoveryTree(
                        named: child,
                        parentFD: directoryFD,
                        runDevice: runDevice,
                        depth: depth + 1,
                        budget: &budget
                    )
                }
            }
            return RecoveryTreeNode(
                name: name, device: named.st_dev, inode: named.st_ino,
                type: type, size: 0, children: children
            )
        case S_IFREG:
            guard named.st_nlink == 1, named.st_size >= 0 else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            let size = UInt64(named.st_size)
            guard budget.bytes <= maximumRecoveryTreeBytes,
                  size <= maximumRecoveryTreeBytes - budget.bytes else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            budget.bytes += size
            let fileFD = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { close(fileFD) }
            var opened = stat()
            guard fstat(fileFD, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino,
                  opened.st_nlink == 1,
                  opened.st_size == named.st_size else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            return RecoveryTreeNode(
                name: name, device: named.st_dev, inode: named.st_ino,
                type: type, size: named.st_size, children: []
            )
        default:
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
    }

    private static func deleteOwnedRecoveryTree(
        _ node: RecoveryTreeNode,
        parentFD: Int32,
        runDevice: dev_t
    ) throws {
        switch node.type {
        case S_IFREG:
            let fileFD = openat(parentFD, node.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { close(fileFD) }
            var opened = stat()
            var named = stat()
            guard fstat(fileFD, &opened) == 0,
                  fstatat(parentFD, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_mode & S_IFMT == S_IFREG,
                  named.st_mode & S_IFMT == S_IFREG,
                  opened.st_dev == runDevice,
                  opened.st_dev == node.device,
                  opened.st_ino == node.inode,
                  named.st_dev == opened.st_dev,
                  named.st_ino == opened.st_ino,
                  opened.st_nlink == 1,
                  named.st_nlink == 1,
                  opened.st_size == node.size,
                  named.st_size == node.size,
                  unlinkat(parentFD, node.name, 0) == 0,
                  try fileKind(at: node.name, directoryFD: parentFD) == nil else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
        case S_IFDIR:
            let directoryFD = openat(parentFD, node.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { close(directoryFD) }
            var opened = stat()
            var named = stat()
            guard fstat(directoryFD, &opened) == 0,
                  fstatat(parentFD, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_mode & S_IFMT == S_IFDIR,
                  named.st_mode & S_IFMT == S_IFDIR,
                  opened.st_dev == runDevice,
                  opened.st_dev == node.device,
                  opened.st_ino == node.inode,
                  named.st_dev == opened.st_dev,
                  named.st_ino == opened.st_ino else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            for child in node.children {
                try deleteOwnedRecoveryTree(child, parentFD: directoryFD, runDevice: runDevice)
            }
            guard try withDirectoryEntries(directoryFD, { $0 }).isEmpty,
                  fstatat(parentFD, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFDIR,
                  named.st_dev == node.device,
                  named.st_ino == node.inode,
                  unlinkat(parentFD, node.name, AT_REMOVEDIR) == 0,
                  try fileKind(at: node.name, directoryFD: parentFD) == nil else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
        default:
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
    }

    private static func ownedRecoveryTreeSnapshots(
        runDirectoryFD: Int32,
        artifactFilename: String,
        runDevice: dev_t
    ) throws -> [RecoveryTreeNode] {
        let entries = try withDirectoryEntries(runDirectoryFD, maximumCount: 4) { $0 }
        var allowed = Set([artifactFilename, "derived", "results"])
        if artifactFilename != "manifest.json" { allowed.insert("manifest.json") }
        guard entries.contains(artifactFilename),
              Set(entries).isSubset(of: allowed) else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        var budget = RecoveryTreeBudget()
        var snapshots: [RecoveryTreeNode] = try ["derived", "results"].compactMap { name in
            guard entries.contains(name) else { return nil }
            let snapshot = try snapshotOwnedRecoveryTree(
                named: name,
                parentFD: runDirectoryFD,
                runDevice: runDevice,
                depth: 1,
                budget: &budget
            )
            guard snapshot.type == S_IFDIR else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            return snapshot
        }
        if artifactFilename != "manifest.json", entries.contains("manifest.json") {
            let manifest = try snapshotOwnedRecoveryTree(
                named: "manifest.json",
                parentFD: runDirectoryFD,
                runDevice: runDevice,
                depth: 1,
                budget: &budget
            )
            guard manifest.type == S_IFREG else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            snapshots.append(manifest)
        }
        return snapshots
    }

    static func finalizeProductionArtifactAndBuildLock(
        at artifactURL: URL,
        temporaryRoot: URL,
        buildLock: AppleXcodeBuildLockOwnership?,
        afterBuildLockReconciliation: () throws -> Void = {},
        removeRunDirectory: (Int32, String) throws -> Void = { rootFD, name in
            guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0 else {
                throw SharedReadingRecoveryJournalError.journalRemovalFailed
            }
        },
        syncRootAfterRemoval: (Int32) throws -> Void = { rootFD in
            guard fsync(rootFD) == 0 else {
                throw SharedReadingRecoveryJournalError.journalRemovalFailed
            }
        },
        reconcileBuildLock: (AppleXcodeBuildLockOwnership) throws -> Void = AppleXcodeBuildLock.reconcileRetainedLock(ownership:)
    ) throws {
        let runDirectory = artifactURL.deletingLastPathComponent()
        let root = temporaryRoot.standardizedFileURL
        guard temporaryRoot.path == root.path,
              artifactURL.path == artifactURL.standardizedFileURL.path,
              runDirectory.deletingLastPathComponent().standardizedFileURL == root,
              runDirectory.lastPathComponent.hasPrefix("rishi-shared-reading-"),
              ["recovery.json", "manifest.json"].contains(artifactURL.lastPathComponent) else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        defer { close(rootFD) }

        try withInterprocessLock(rootFD) {
            let runName = runDirectory.lastPathComponent
            let filename = artifactURL.lastPathComponent
            let runFD = openat(rootFD, runName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard runFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
            defer { close(runFD) }
            try withDirectoryLockAlreadySerialized(runFD) {
                var runDetails = stat()
                var namedRunDetails = stat()
                guard fstat(runFD, &runDetails) == 0,
                      fstatat(rootFD, runName, &namedRunDetails, AT_SYMLINK_NOFOLLOW) == 0,
                      namedRunDetails.st_mode & S_IFMT == S_IFDIR,
                      runDetails.st_dev == namedRunDetails.st_dev,
                      runDetails.st_ino == namedRunDetails.st_ino,
                      try fileKind(at: filename, directoryFD: runFD) == S_IFREG else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                let ownedTrees = try ownedRecoveryTreeSnapshots(
                    runDirectoryFD: runFD,
                    artifactFilename: filename,
                    runDevice: runDetails.st_dev
                )

                let artifactFD = openat(runFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard artifactFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
                var artifactDetails = stat()
                let rawData: Data
                do {
                    guard fstat(artifactFD, &artifactDetails) == 0,
                          artifactDetails.st_mode & S_IFMT == S_IFREG,
                          artifactDetails.st_size >= 0,
                          artifactDetails.st_size <= off_t(maximumEncodedJournalBytes) else {
                        throw SharedReadingRecoveryJournalError.malformedArtifact
                    }
                    rawData = try readAll(from: artifactFD, maximumBytes: maximumEncodedJournalBytes)
                } catch {
                    close(artifactFD)
                    throw error
                }
                close(artifactFD)

                var runDirectoryRemoved = false
                do {
                    // The ownership artifact must remain visible for the entire
                    // lifetime of a present retained lock. Reconcile first;
                    // absence is idempotent on retry. Every subsequent failure
                    // restores the exact bounded artifact bytes.
                    if let buildLock {
                        try reconcileBuildLock(buildLock)
                        try afterBuildLockReconciliation()
                    }
                    for tree in ownedTrees {
                        try deleteOwnedRecoveryTree(
                            tree,
                            parentFD: runFD,
                            runDevice: runDetails.st_dev
                        )
                    }
                    guard fsync(runFD) == 0,
                          unlinkat(runFD, filename, 0) == 0,
                          fsync(runFD) == 0,
                          try withDirectoryEntries(runFD, { $0 }).isEmpty else {
                        throw SharedReadingRecoveryJournalError.journalRemovalFailed
                    }
                    try removeRunDirectory(rootFD, runName)
                    runDirectoryRemoved = true
                    try syncRootAfterRemoval(rootFD)
                    guard try fileKind(at: runName, directoryFD: rootFD) == nil else {
                        throw SharedReadingRecoveryJournalError.journalRemovalFailed
                    }
                } catch {
                    do {
                        try restoreRecoveryArtifact(
                            rawData,
                            permissions: artifactDetails.st_mode & mode_t(0o777),
                            runDirectoryPermissions: runDetails.st_mode & mode_t(0o777),
                            rootFD: rootFD,
                            originalRunFD: runFD,
                            runName: runName,
                            filename: filename,
                            runDirectoryRemoved: runDirectoryRemoved
                        )
                    } catch {
                        throw SharedReadingRecoveryJournalError.cleanupIncomplete
                    }
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
            }
        }
    }

    private static func restoreRecoveryArtifact(
        _ data: Data,
        permissions: mode_t,
        runDirectoryPermissions: mode_t,
        rootFD: Int32,
        originalRunFD: Int32,
        runName: String,
        filename: String,
        runDirectoryRemoved: Bool
    ) throws {
        let targetFD: Int32
        var closesTarget = false
        if runDirectoryRemoved {
            guard try fileKind(at: runName, directoryFD: rootFD) == nil,
                  mkdirat(rootFD, runName, runDirectoryPermissions) == 0 else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
            targetFD = openat(rootFD, runName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard targetFD >= 0 else { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
            closesTarget = true
        } else {
            var original = stat()
            var named = stat()
            guard fstat(originalRunFD, &original) == 0,
                  fstatat(rootFD, runName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFDIR,
                  original.st_dev == named.st_dev,
                  original.st_ino == named.st_ino else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
            targetFD = originalRunFD
        }
        defer { if closesTarget { close(targetFD) } }

        try writeDataAtomically(data, to: targetFD, filename: filename, permissions: permissions)
        guard fsync(targetFD) == 0,
              fsync(rootFD) == 0 else {
            throw SharedReadingRecoveryJournalError.cleanupIncomplete
        }
        let verificationFD = openat(targetFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard verificationFD >= 0 else { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
        defer { close(verificationFD) }
        guard try readAll(from: verificationFD, maximumBytes: maximumEncodedJournalBytes) == data else {
            throw SharedReadingRecoveryJournalError.cleanupIncomplete
        }
    }

    private static func readRecoveryArtifactData(at artifactURL: URL, temporaryRoot: URL) throws -> Data {
        let root = temporaryRoot.standardizedFileURL
        let runDirectory = artifactURL.deletingLastPathComponent().standardizedFileURL
        guard runDirectory.deletingLastPathComponent().path == root.path,
              artifactURL.standardizedFileURL.path == artifactURL.path,
              runDirectory.lastPathComponent.hasPrefix("rishi-shared-reading-"),
              ["recovery.json", "manifest.json"].contains(artifactURL.lastPathComponent) else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        defer { close(rootFD) }
        let runFD = openat(rootFD, runDirectory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard runFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        defer { close(runFD) }
        guard try fileKind(at: artifactURL.lastPathComponent, directoryFD: runFD) == S_IFREG else {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let fileFD = openat(runFD, artifactURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact }
        defer { close(fileFD) }
        var details = stat()
        guard fstat(fileFD, &details) == 0,
              details.st_mode & S_IFMT == S_IFREG,
              details.st_size >= 0,
              details.st_size <= off_t(maximumEncodedJournalBytes) else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
        return try readAll(from: fileFD, maximumBytes: maximumEncodedJournalBytes)
    }

    private static func validateArtifactLocation(
        _ artifact: RecoveryArtifact,
        temporaryRoot: URL
    ) throws {
        let runDirectory = artifact.url.deletingLastPathComponent().standardizedFileURL
        guard !artifact.runID.isEmpty,
              !artifact.runID.contains("/"),
              !artifact.runID.contains(".."),
              runDirectory.deletingLastPathComponent().path == temporaryRoot.standardizedFileURL.path,
              runDirectory.lastPathComponent == "rishi-shared-reading-\(artifact.runID)" else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    private static func normalizedJournal(
        _ state: RecoveryState,
        at artifactURL: URL,
        configuredBuildLockURL: URL,
        validation: RecoveryArtifactValidation
    ) throws -> RecoveryArtifact {
        try validateAccounts(state.accounts, validation: validation)
        for group in state.processGroups {
            guard group.processGroupID > 0,
                  group.leader.pid == group.processGroupID,
                  validIdentity(group.leader) else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
        }
        guard state.processes.allSatisfy(validIdentity) else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
        for device in state.simulatorDevices {
            guard device.name == SharedReadingOwnedResourceContract.disposableSimulatorName(runID: state.runID),
                  device.deviceTypeIdentifier == SharedReadingOwnedResourceContract.disposableSimulatorDeviceTypeIdentifier,
                  validation.allowedRuntimeIdentifiers.contains(device.runtimeIdentifier),
                  device.udid?.isEmpty != true else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
        }
        for launch in state.pendingCatalystLaunches {
            let expectedBundle: String
            switch launch.kind {
            case .runner: expectedBundle = validation.runnerBundleIdentifier
            case .app: expectedBundle = validation.appBundleIdentifier
            }
            guard launch.role == .owner,
                  launch.bundleIdentifier == expectedBundle,
                  launch.baselineIdentities.allSatisfy(validIdentity),
                  launch.registeredIdentity.map(validIdentity) ?? true else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
        }
        let runRoot = artifactURL.deletingLastPathComponent().standardizedFileURL
        let reserved = SharedReadingOwnedResourceContract.secretTestRunRelativePaths
        let secretURLs = try Set(state.secretArtifactRelativePaths.map { path in
            guard reserved.contains(path), isSafeRelativePath(path) else {
                throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
            }
            let url = runRoot.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(runRoot.path + "/"),
                  url.path == runRoot.appendingPathComponent(path).path else {
                throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
            }
            return url
        })
        if let buildLock = state.buildLock {
            guard buildLock.path == configuredBuildLockURL.standardizedFileURL.path,
                  configuredBuildLockURL.path == configuredBuildLockURL.standardizedFileURL.path,
                  !buildLock.token.isEmpty,
                  !buildLock.generation.isEmpty,
                  validIdentity(buildLock.owner) else {
                throw SharedReadingRecoveryJournalError.malformedArtifact
            }
        }
        return RecoveryArtifact(
            url: artifactURL,
            runID: state.runID,
            accounts: state.accounts,
            processGroups: state.processGroups,
            processes: state.processes,
            simulatorDevices: state.simulatorDevices,
            pendingCatalystLaunches: state.pendingCatalystLaunches,
            secretArtifactURLs: secretURLs,
            buildLock: state.buildLock,
            isLegacy: false
        )
    }

    private static func normalizedLegacy(
        runID: String,
        accounts: [RecordedAccount],
        at artifactURL: URL,
        validation: RecoveryArtifactValidation
    ) throws -> RecoveryArtifact {
        try validateAccounts(accounts, validation: validation)
        return RecoveryArtifact(
            url: artifactURL,
            runID: runID,
            accounts: accounts,
            processGroups: [],
            processes: [],
            simulatorDevices: [],
            pendingCatalystLaunches: [],
            secretArtifactURLs: [],
            buildLock: nil,
            isLegacy: true
        )
    }

    private static func validateAccounts(
        _ accounts: [RecordedAccount],
        validation: RecoveryArtifactValidation
    ) throws {
        guard Set(accounts.map { $0.role.rawValue }).count == accounts.count,
              Set(accounts.map { $0.email.lowercased() }).count == accounts.count,
              accounts.allSatisfy({ !$0.email.isEmpty && validation.emailIsInConfiguredNamespace($0.email) }) else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    private static func validIdentity(_ identity: OwnedProcessIdentity) -> Bool {
        identity.pid > 0
    }

    private static func validateJournalJSONShape(_ object: [String: Any]) throws {
        try validateObjectArray(object["accounts"], required: ["email", "role", "outcome"])
        try validateObjectArray(object["processes"], required: ["pid", "birthTimeSeconds", "birthTimeMicroseconds"])
        try validateObjectArray(object["processGroups"], required: ["processGroupID", "leader"]) { value in
            guard let object = value as? [String: Any] else { throw SharedReadingRecoveryJournalError.malformedArtifact }
            try validateObject(object["leader"], required: ["pid", "birthTimeSeconds", "birthTimeMicroseconds"])
        }
        try validateObjectArray(object["simulatorDevices"], required: ["name", "deviceTypeIdentifier", "runtimeIdentifier"], optional: ["udid"])
        try validateObjectArray(object["pendingCatalystLaunches"], required: ["role", "kind", "bundleIdentifier", "baselineIdentities"], optional: ["registeredIdentity"]) { value in
            guard let launch = value as? [String: Any] else { throw SharedReadingRecoveryJournalError.malformedArtifact }
            try validateObjectArray(launch["baselineIdentities"], required: ["pid", "birthTimeSeconds", "birthTimeMicroseconds"])
            if let registered = launch["registeredIdentity"], !(registered is NSNull) {
                try validateObject(registered, required: ["pid", "birthTimeSeconds", "birthTimeMicroseconds"])
            }
        }
        guard object["secretArtifactRelativePaths"] is [String] else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
        if let lock = object["buildLock"], !(lock is NSNull) {
            try validateObject(lock, required: ["path", "token", "generation", "owner"])
            guard let lockObject = lock as? [String: Any] else { throw SharedReadingRecoveryJournalError.malformedArtifact }
            try validateObject(lockObject["owner"], required: ["pid", "birthTimeSeconds", "birthTimeMicroseconds"])
        }
    }

    private static func validateObjectArray(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String> = [],
        nested: ((Any) throws -> Void)? = nil
    ) throws {
        guard let values = value as? [Any] else { throw SharedReadingRecoveryJournalError.malformedArtifact }
        for value in values {
            try validateObject(value, required: required, optional: optional)
            try nested?(value)
        }
    }

    private static func validateObject(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        guard let object = value as? [String: Any],
              required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    private static func validateFixtureShape(_ value: Any?) throws {
        try validateObject(value, required: ["role", "format", "basename", "sha256", "byteSize"])
    }

    private static func validatePersistedAccountShape(_ value: Any?, role: TestAccountRole) throws {
        try validateObject(value, required: ["role", "email"])
        guard let object = value as? [String: Any], object["role"] as? String == role.rawValue else {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    /// Recover recorded individual identities without ever treating a reused
    /// PID as owned. A missing or birth-mismatched PID is already absent.
    public static func recoverProcesses(
        _ processes: [OwnedProcessIdentity],
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        signal: @escaping @Sendable (Int32, Int32) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        var failures = false
        for process in processes {
            // Darwin has no pidfd-style identity-bound signal. This full birth
            // identity comparison is repeated immediately before each kill,
            // which is the strongest available primitive but not atomic with
            // the following kill(2).
            guard liveIdentity(process.pid) == process else { continue }
            signal(process.pid, SIGTERM)
            if try await waitForIdentityAbsence(process, liveIdentity: liveIdentity, sleep: sleep) { continue }
            guard liveIdentity(process.pid) == process else { continue }
            signal(process.pid, SIGKILL)
            if try await waitForIdentityAbsence(process, liveIdentity: liveIdentity, sleep: sleep) { continue }
            failures = true
        }
        if failures { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
    }

    /// Group recovery has explicit inventory seams so unit tests never signal a
    /// real process. A live PGID leader whose birth time differs is a reused
    /// group and therefore an error, not cleanup authority.
    public static func recoverProcessGroups(
        _ groups: [OwnedProcessGroup],
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        members: @escaping @Sendable (Int32) throws -> [Int32],
        processGroup: @escaping @Sendable (Int32) -> Int32?,
        signal: @escaping @Sendable (Int32, Int32) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        var failures = false
        for group in groups {
            do {
                try await recoverProcessGroup(
                    group,
                    liveIdentity: liveIdentity,
                    members: members,
                    processGroup: processGroup,
                    signal: signal,
                    sleep: sleep
                )
            } catch {
                failures = true
            }
        }
        if failures { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
    }

    private static func recoverProcessGroup(
        _ group: OwnedProcessGroup,
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        members: @escaping @Sendable (Int32) throws -> [Int32],
        processGroup: @escaping @Sendable (Int32) -> Int32?,
        signal: @escaping @Sendable (Int32, Int32) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        for phase in [SIGTERM, SIGKILL] {
            for _ in 0..<6 {
                let leader = liveIdentity(group.leader.pid)
                if let leader, leader != group.leader { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
                let snapshot = try members(group.processGroupID)
                if snapshot.isEmpty { return }
                for pid in snapshot {
                    // A current process whose PID equals the old PGID can only
                    // be trusted when it is the original leader identity.
                    if pid == group.processGroupID, let identity = liveIdentity(pid), identity != group.leader {
                        throw SharedReadingRecoveryJournalError.cleanupIncomplete
                    }
                    // Recheck the full birth identity and PGID immediately
                    // before kill(2). Darwin cannot make this validation and
                    // signal atomic, so a mismatch always fails closed.
                    guard let identity = liveIdentity(pid), processGroup(pid) == group.processGroupID,
                          liveIdentity(pid) == identity, processGroup(pid) == group.processGroupID else { continue }
                    signal(pid, phase)
                }
                try await sleep(.milliseconds(25))
            }
        }
        if !(try members(group.processGroupID)).isEmpty { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
    }

    private static func waitForIdentityAbsence(
        _ identity: OwnedProcessIdentity,
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> Bool {
        for _ in 0..<6 {
            if liveIdentity(identity.pid) != identity { return true }
            try await sleep(.milliseconds(25))
        }
        return liveIdentity(identity.pid) != identity
    }
}

private struct RecoveryState: Codable, Equatable {
    var runID: String
    var accounts: [RecordedAccount] = []
    var processGroups: Set<OwnedProcessGroup> = []
    var processes: Set<OwnedProcessIdentity> = []
    var simulatorDevices: Set<OwnedSimulatorDevice> = []
    var pendingCatalystLaunches: Set<PendingCatalystLaunch> = []
    var secretArtifactRelativePaths: Set<String> = []
    var buildLock: AppleXcodeBuildLockOwnership?

    init(runID: String) {
        self.runID = runID
    }

    private enum CodingKeys: String, CodingKey {
        case runID, accounts, processGroups, processes, simulatorDevices
        case pendingCatalystLaunches, secretArtifactRelativePaths, buildLock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        accounts = try container.decode([RecordedAccount].self, forKey: .accounts)
        processGroups = try Self.unique(try container.decode([OwnedProcessGroup].self, forKey: .processGroups), codingPath: container.codingPath)
        processes = try Self.unique(try container.decode([OwnedProcessIdentity].self, forKey: .processes), codingPath: container.codingPath)
        simulatorDevices = try Self.unique(try container.decode([OwnedSimulatorDevice].self, forKey: .simulatorDevices), codingPath: container.codingPath)
        pendingCatalystLaunches = try Self.unique(try container.decode([PendingCatalystLaunch].self, forKey: .pendingCatalystLaunches), codingPath: container.codingPath)
        secretArtifactRelativePaths = try Self.unique(try container.decode([String].self, forKey: .secretArtifactRelativePaths), codingPath: container.codingPath)
        buildLock = try container.decodeIfPresent(AppleXcodeBuildLockOwnership.self, forKey: .buildLock)
        guard Set(accounts.map(\.email)).count == accounts.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Duplicate account recovery entry."))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(accounts.sorted(by: Self.accountsInOrder), forKey: .accounts)
        try container.encode(processGroups.sorted(by: Self.processGroupsInOrder), forKey: .processGroups)
        try container.encode(processes.sorted(by: Self.processesInOrder), forKey: .processes)
        try container.encode(simulatorDevices.sorted(by: Self.simulatorDevicesInOrder), forKey: .simulatorDevices)
        try container.encode(pendingCatalystLaunches.sorted(by: Self.launchesInOrder), forKey: .pendingCatalystLaunches)
        try container.encode(secretArtifactRelativePaths.sorted(), forKey: .secretArtifactRelativePaths)
        try container.encodeIfPresent(buildLock, forKey: .buildLock)
    }

    var isEmpty: Bool {
        accounts.isEmpty
            && processGroups.isEmpty
            && processes.isEmpty
            && simulatorDevices.isEmpty
            && pendingCatalystLaunches.isEmpty
            && secretArtifactRelativePaths.isEmpty
            && buildLock == nil
    }

    private static func unique<T: Hashable>(_ values: [T], codingPath: [any CodingKey]) throws -> Set<T> {
        let set = Set(values)
        guard set.count == values.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Duplicate recovery entry."))
        }
        return set
    }

    static func accountsInOrder(_ lhs: RecordedAccount, _ rhs: RecordedAccount) -> Bool {
        if lhs.email != rhs.email { return lhs.email < rhs.email }
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        return lhs.outcome.rawValue < rhs.outcome.rawValue
    }

    static func processesInOrder(_ lhs: OwnedProcessIdentity, _ rhs: OwnedProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.birthTimeSeconds != rhs.birthTimeSeconds { return lhs.birthTimeSeconds < rhs.birthTimeSeconds }
        return lhs.birthTimeMicroseconds < rhs.birthTimeMicroseconds
    }

    static func processGroupsInOrder(_ lhs: OwnedProcessGroup, _ rhs: OwnedProcessGroup) -> Bool {
        if lhs.processGroupID != rhs.processGroupID { return lhs.processGroupID < rhs.processGroupID }
        return processesInOrder(lhs.leader, rhs.leader)
    }

    static func simulatorDevicesInOrder(_ lhs: OwnedSimulatorDevice, _ rhs: OwnedSimulatorDevice) -> Bool {
        if lhs.udid != rhs.udid {
            switch (lhs.udid, rhs.udid) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(left), .some(right)): return left < right
            case (nil, nil): break
            }
        }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.deviceTypeIdentifier != rhs.deviceTypeIdentifier { return lhs.deviceTypeIdentifier < rhs.deviceTypeIdentifier }
        return lhs.runtimeIdentifier < rhs.runtimeIdentifier
    }

    private static func launchesInOrder(_ lhs: PendingCatalystLaunch, _ rhs: PendingCatalystLaunch) -> Bool {
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.bundleIdentifier != rhs.bundleIdentifier { return lhs.bundleIdentifier < rhs.bundleIdentifier }
        let leftBaseline = lhs.baselineIdentities.sorted(by: processesInOrder)
        let rightBaseline = rhs.baselineIdentities.sorted(by: processesInOrder)
        if leftBaseline != rightBaseline { return leftBaseline.lexicographicallyPrecedes(rightBaseline, by: processesInOrder) }
        switch (lhs.registeredIdentity, rhs.registeredIdentity) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)): return processesInOrder(left, right)
        case (nil, nil): return false
        }
    }
}

struct RecordedAccount: Codable, Equatable, Sendable {
    var email: String
    var role: TestAccountRole
    var outcome: TestAccountProvisioningOutcome
}

private struct PersistedHostRecoveryManifest: Decodable {
    struct Account: Decodable {
        let role: TestAccountRole
        let email: String
    }

    let runID: String
    let owner: Account
    let participant: Account
}

private struct ProductionSimulatorInventory: Decodable {
    struct Device: Decodable {
        let udid: String
        let name: String
        let deviceTypeIdentifier: String
    }

    let devices: [String: [Device]]
}

private struct ProductionSimulatorDevice: Sendable {
    let udid: String
    let name: String
    let deviceTypeIdentifier: String
    let runtimeIdentifier: String
}

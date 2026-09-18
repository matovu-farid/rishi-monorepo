import Darwin
import Foundation

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
        try mutate { $0.buildLock = ownership }
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
        if let existing = try fileKind(at: filename, directoryFD: directoryFD), existing != S_IFREG {
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        let temporaryName = ".\(filename).\(UUID().uuidString).tmp"
        let fileFD = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fileFD >= 0 else { throw SharedReadingRecoveryJournalError.permissionsNotApplied }
        var shouldRemoveTemporary = true
        defer {
            close(fileFD)
            if shouldRemoveTemporary { _ = unlinkat(directoryFD, temporaryName, 0) }
        }
        guard fchmod(fileFD, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
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

    private static func withDirectoryEntries<T>(_ directoryFD: Int32, _ operation: ([String]) throws -> T) throws -> T {
        let duplicateFD = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicateFD >= 0, let directory = fdopendir(duplicateFD) else {
            if duplicateFD >= 0 { close(duplicateFD) }
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
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

public extension SharedReadingRecoveryJournal {
    /// Recover recorded individual identities without ever treating a reused
    /// PID as owned. A missing or birth-mismatched PID is already absent.
    static func recoverProcesses(
        _ processes: [OwnedProcessIdentity],
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        signal: @escaping @Sendable (Int32, Int32) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        var failures = false
        for process in processes {
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
    static func recoverProcessGroups(
        _ groups: [OwnedProcessGroup],
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        members: @escaping @Sendable (Int32) -> [Int32],
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
        members: @escaping @Sendable (Int32) -> [Int32],
        processGroup: @escaping @Sendable (Int32) -> Int32?,
        signal: @escaping @Sendable (Int32, Int32) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        for phase in [SIGTERM, SIGKILL] {
            for _ in 0..<6 {
                let leader = liveIdentity(group.leader.pid)
                if let leader, leader != group.leader { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
                let snapshot = members(group.processGroupID)
                if snapshot.isEmpty { return }
                for pid in snapshot {
                    // A current process whose PID equals the old PGID can only
                    // be trusted when it is the original leader identity.
                    if pid == group.processGroupID, let identity = liveIdentity(pid), identity != group.leader {
                        throw SharedReadingRecoveryJournalError.cleanupIncomplete
                    }
                    guard let identity = liveIdentity(pid), processGroup(pid) == group.processGroupID,
                          liveIdentity(pid) == identity, processGroup(pid) == group.processGroupID else { continue }
                    signal(pid, phase)
                }
                try await sleep(.milliseconds(25))
            }
        }
        if !members(group.processGroupID).isEmpty { throw SharedReadingRecoveryJournalError.cleanupIncomplete }
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

    private static func accountsInOrder(_ lhs: RecordedAccount, _ rhs: RecordedAccount) -> Bool {
        if lhs.email != rhs.email { return lhs.email < rhs.email }
        if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
        return lhs.outcome.rawValue < rhs.outcome.rawValue
    }

    private static func processesInOrder(_ lhs: OwnedProcessIdentity, _ rhs: OwnedProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.birthTimeSeconds != rhs.birthTimeSeconds { return lhs.birthTimeSeconds < rhs.birthTimeSeconds }
        return lhs.birthTimeMicroseconds < rhs.birthTimeMicroseconds
    }

    private static func processGroupsInOrder(_ lhs: OwnedProcessGroup, _ rhs: OwnedProcessGroup) -> Bool {
        if lhs.processGroupID != rhs.processGroupID { return lhs.processGroupID < rhs.processGroupID }
        return processesInOrder(lhs.leader, rhs.leader)
    }

    private static func simulatorDevicesInOrder(_ lhs: OwnedSimulatorDevice, _ rhs: OwnedSimulatorDevice) -> Bool {
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

private struct RecordedAccount: Codable, Equatable {
    var email: String
    var role: TestAccountRole
    var outcome: TestAccountProvisioningOutcome
}

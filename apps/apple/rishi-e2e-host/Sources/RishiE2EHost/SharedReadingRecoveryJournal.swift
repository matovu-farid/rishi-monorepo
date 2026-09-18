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
}

public final class SharedReadingRecoveryJournal: @unchecked Sendable, TestAccountLifecycleRecording, OwnedProcessRecording {
    public let url: URL

    private let lock = NSLock()
    private var state: RecoveryState

    public init(url: URL, runID: String) throws {
        self.url = url

        if FileManager.default.fileExists(atPath: url.path) {
            let decoded = try Self.decodeState(from: url)
            guard decoded.runID == runID else {
                throw SharedReadingRecoveryJournalError.runIDMismatch
            }
            state = decoded
        } else {
            state = RecoveryState(runID: runID)
        }
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
            guard state.isEmpty else {
                throw SharedReadingRecoveryJournalError.cleanupIncomplete
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw SharedReadingRecoveryJournalError.journalRemovalFailed
            }
        }
    }

    public static func unresolvedArtifact(in root: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where child.lastPathComponent.hasPrefix("rishi-shared-reading-") {
            guard try Self.fileKind(at: child) == S_IFDIR else {
                throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
            }
            for name in ["recovery.json", "manifest.json"] {
                let enumeratedCandidate = child.appendingPathComponent(name)
                guard let kind = try Self.fileKind(at: enumeratedCandidate) else { continue }
                guard kind == S_IFREG else {
                    throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
                }
                return root.appendingPathComponent(child.lastPathComponent).appendingPathComponent(name)
            }
        }
        return nil
    }

    private func mutate(_ update: (inout RecoveryState) throws -> Void) throws {
        try lock.withLock {
            var candidate = state
            try update(&candidate)
            try Self.write(candidate, to: url)
            state = candidate
        }
    }

    private static func decodeState(from url: URL) throws -> RecoveryState {
        do {
            return try JSONDecoder().decode(RecoveryState.self, from: Data(contentsOf: url))
        } catch {
            throw SharedReadingRecoveryJournalError.malformedArtifact
        }
    }

    private static func write(_ state: RecoveryState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SharedReadingRecoveryJournalError.permissionsNotApplied
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }

    private static func fileKind(at url: URL) throws -> mode_t? {
        var details = stat()
        guard lstat(url.path, &details) == 0 else {
            if errno == ENOENT { return nil }
            throw SharedReadingRecoveryJournalError.unsafeRecoveryArtifact
        }
        return details.st_mode & S_IFMT
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

    var isEmpty: Bool {
        accounts.isEmpty
            && processGroups.isEmpty
            && processes.isEmpty
            && simulatorDevices.isEmpty
            && pendingCatalystLaunches.isEmpty
            && secretArtifactRelativePaths.isEmpty
            && buildLock == nil
    }
}

private struct RecordedAccount: Codable, Equatable {
    var email: String
    var role: TestAccountRole
    var outcome: TestAccountProvisioningOutcome
}

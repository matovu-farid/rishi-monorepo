import Darwin
import Foundation

public struct OwnedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let birthTimeSeconds: UInt64
    public let birthTimeMicroseconds: UInt64
}

public struct OwnedProcessGroup: Codable, Hashable, Sendable {
    public let processGroupID: Int32
    public let leader: OwnedProcessIdentity
}

public struct OwnedSimulatorDevice: Codable, Hashable, Sendable {
    public let udid: String?
    public let name: String
    public let deviceTypeIdentifier: String
    public let runtimeIdentifier: String
}

public struct PendingCatalystLaunch: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case runner, app }
    public let role: TestAccountRole
    public let kind: Kind
    public let bundleIdentifier: String
    public let baselineIdentities: Set<OwnedProcessIdentity>
    public let registeredIdentity: OwnedProcessIdentity?
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
    case missingCatalystLaunchIntent
    case invalidSecretArtifactPath
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

    public func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {
        try mutate { $0.processes.insert(identity) }
    }

    public func recordOwnedSimulatorDevice(_ device: OwnedSimulatorDevice) throws {
        try mutate { $0.simulatorDevices.insert(device) }
    }

    public func recordCatalystLaunchIntent(_ intent: PendingCatalystLaunch) throws {
        try mutate { $0.pendingCatalystLaunches.insert(intent) }
    }

    public func recordCatalystRegisteredIdentity(
        _ identity: OwnedProcessIdentity,
        role: TestAccountRole,
        kind: PendingCatalystLaunch.Kind
    ) throws {
        try mutate { state in
            guard let intent = state.pendingCatalystLaunches.first(where: {
                $0.role == role && $0.kind == kind && $0.registeredIdentity == nil
            }) else {
                throw SharedReadingRecoveryJournalError.missingCatalystLaunchIntent
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

    public func recordSecretArtifact(relativePath: String) throws {
        guard Self.isSafeRelativePath(relativePath) else {
            throw SharedReadingRecoveryJournalError.invalidSecretArtifactPath
        }
        try mutate { $0.secretArtifactRelativePaths.insert(relativePath) }
    }

    public func removeSecretArtifact(relativePath: String) throws {
        try mutate { $0.secretArtifactRelativePaths.remove(relativePath) }
    }

    public func recordBuildLock(_ ownership: AppleXcodeBuildLockOwnership) throws {
        try mutate { $0.buildLock = ownership }
    }

    public func clearBuildLock() throws {
        try mutate { $0.buildLock = nil }
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where child.lastPathComponent.hasPrefix("rishi-shared-reading-") {
            guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            for name in ["recovery.json", "manifest.json"] {
                let enumeratedCandidate = child.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: enumeratedCandidate.path) else { continue }
                guard try enumeratedCandidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
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

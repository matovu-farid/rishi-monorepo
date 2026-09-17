import Foundation

private func reportProcessFailure(role: TestAccountRole, result: ProcessResult) {
    let combined = [result.stdout, result.stderr]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    guard !combined.isEmpty else {
        FileHandle.standardError.write(Data("\(role.rawValue) XCTest exited with status \(result.exitStatus) and produced no diagnostics.\n".utf8))
        return
    }
    let suffix = String(combined.suffix(12_000))
    FileHandle.standardError.write(Data("\n--- \(role.rawValue) XCTest diagnostics ---\n\(suffix)\n--- end diagnostics ---\n".utf8))
}

public enum SharedReadingDestination: String, Codable, Sendable, Equatable {
    case catalyst
    case iPhone17Pro
}

public struct SharedReadingPeerHandle: Sendable {
    public let role: TestAccountRole
    public let status: Int32
    fileprivate let process: (any ProcessHandle)?

    public init(role: TestAccountRole, status: Int32 = 0) {
        self.role = role
        self.status = status
        self.process = nil
    }

    fileprivate init(role: TestAccountRole, process: any ProcessHandle) {
        self.role = role
        self.status = 0
        self.process = process
    }
}

public protocol TestAccountManaging: Sendable {
    func preflight() async throws
    func create(role: TestAccountRole) async throws -> TestAccount
    func waitForBookUpload(_ account: TestAccount, expectedSHA256: String, timeout: Duration) async throws
    func delete(_ account: TestAccount) async throws
    func verifyDeleted(_ account: TestAccount) async throws
}

public protocol SharedReadingPeerRunner: Sendable {
    func preflight() async throws
    func reset(target: SharedReadingDestination) async throws
    func prepare(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination) async throws
    func launch(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination, inviteToken: String?) async throws -> SharedReadingPeerHandle
    func wait(_ handle: SharedReadingPeerHandle) async throws -> ProcessResult
    func cancel(_ handle: SharedReadingPeerHandle) async throws
}

public struct XCTestPeerProcessRunner: SharedReadingPeerRunner {
    public struct Configuration: Sendable, Equatable {
        public let projectPath: URL
        public let scheme: String
        public let simulatorID: String
        public let derivedDataRoot: URL
        public let resultBundleRoot: URL
        public let allowSimulatorReset: Bool
        public let fixturePath: URL?
        public let rendezvousEnvironment: [String: String]
        public let usePreparedProducts: Bool

        public init(projectPath: URL, scheme: String = "rishi-mcp", simulatorID: String, derivedDataRoot: URL, resultBundleRoot: URL, allowSimulatorReset: Bool = false, fixturePath: URL? = nil, rendezvousEnvironment: [String: String] = [:], usePreparedProducts: Bool = false) {
            self.projectPath = projectPath
            self.scheme = scheme
            self.simulatorID = simulatorID
            self.derivedDataRoot = derivedDataRoot
            self.resultBundleRoot = resultBundleRoot
            self.allowSimulatorReset = allowSimulatorReset
            self.fixturePath = fixturePath
            self.rendezvousEnvironment = rendezvousEnvironment
            self.usePreparedProducts = usePreparedProducts
        }
    }

    private let configuration: Configuration
    private let processRunner: any ProcessRunner

    public init(configuration: Configuration, processRunner: any ProcessRunner = FoundationProcessRunner()) {
        self.configuration = configuration
        self.processRunner = processRunner
    }

    public func preflight() async throws {
        try ResourcePreflight.requireSufficient(for: configuration.derivedDataRoot)
        let xcode = try await processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/xcodebuild",
            arguments: ["-version"]
        ))
        guard xcode.succeeded else {
            reportProcessFailure(role: .owner, result: xcode)
            throw HostError.processFailed(role: .owner, status: xcode.exitStatus)
        }
        // Validate the selected device before creating accounts or resolving
        // packages. This check must also run when erase/reset is disabled;
        // otherwise a typo or stale UDID would only fail after the expensive
        // build phase has started.
        try await verifyConfiguredSimulator()
        try await preflightPackageResolution()
    }

    public func reset(target: SharedReadingDestination) async throws {
        guard target == .iPhone17Pro else { return }
        guard configuration.allowSimulatorReset else {
            throw HostError.simulatorResetNotPermitted
        }
        try await verifyConfiguredSimulator()
        // Xcode may leave the selected simulator booted. CoreSimulator does
        // not permit erase while booted, so shut down only this exact device
        // before wiping its local account state.
        let shutdown = try await processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "shutdown", configuration.simulatorID]
        ))
        guard Self.simulatorShutdownCompleted(shutdown) else {
            reportProcessFailure(role: .participant, result: shutdown)
            throw HostError.processFailed(role: .participant, status: shutdown.exitStatus)
        }
        let result = try await processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "erase", configuration.simulatorID]
        ))
        guard result.succeeded else {
            reportProcessFailure(role: .participant, result: result)
            throw HostError.processFailed(role: .participant, status: result.exitStatus)
        }
    }

    static func simulatorShutdownCompleted(_ result: ProcessResult) -> Bool {
        result.succeeded || result.stderr.contains("Unable to shutdown device in current state: Shutdown")
    }

    private func verifyConfiguredSimulator() async throws {
        let devices = try await processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "-j"]
        ))
        guard devices.succeeded else {
            throw HostError.simulatorServiceUnavailable
        }
        guard let data = devices.stdout.data(using: .utf8) else {
            throw HostError.simulatorServiceUnavailable
        }
        guard Self.isConfiguredIPhone17ProAvailable(in: data, simulatorID: configuration.simulatorID) else {
            throw HostError.simulatorNotFound
        }
    }

    static func isConfiguredIPhone17ProAvailable(in data: Data, simulatorID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["devices"] as? [String: [[String: Any]]] else {
            return false
        }
        return groups.values.flatMap({ $0 }).contains(where: {
            ($0["name"] as? String) == "iPhone 17 Pro"
                && ($0["udid"] as? String) == simulatorID
        })
    }

    public func prepare(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination) async throws {
        let suffix = destination.rawValue
        let derivedData = configuration.derivedDataRoot.appendingPathComponent(suffix, isDirectory: true)
        if configuration.usePreparedProducts,
           FileManager.default.fileExists(atPath: derivedData.appendingPathComponent("Build/Products", isDirectory: true).path) {
            return
        }
        // The package preflight intentionally creates this destination
        // directory while populating the run-scoped SourcePackages cache.
        // The parent run directory is unique, so its existence is not a
        // collision; the cross-process build lock protects the active build.
        try ResourcePreflight.requireSufficient(for: derivedData)
        let build = try await runBounded(ProcessRequest(
            executablePath: "/usr/bin/xcodebuild",
            arguments: ["build-for-testing"] + commonArguments(for: destination, derivedData: derivedData),
            environment: [:]
        ), role: role, timeout: .seconds(1_800))
        guard build.succeeded else {
            reportProcessFailure(role: role, result: build)
            throw HostError.processFailed(role: role, status: build.exitStatus)
        }
    }

    public func launch(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination, inviteToken: String? = nil) async throws -> SharedReadingPeerHandle {
        let derivedData = configuration.derivedDataRoot.appendingPathComponent(destination.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: derivedData.path) else {
            throw HostError.preparedDataMissing(derivedData)
        }
        let resultBundle = configuration.resultBundleRoot.appendingPathComponent("\(manifest.runID)-\(role.rawValue).xcresult")
        let testName = role == .owner ? "rishiUITests/SharedReadingOwnerUITests" : "rishiUITests/SharedReadingParticipantUITests"
        let testRunSpecification = try makeRoleTestRunSpecification(
            role: role,
            derivedData: derivedData,
            manifest: manifest,
            inviteToken: inviteToken
        )
        let request = ProcessRequest(
            executablePath: "/usr/bin/xcodebuild",
            arguments: [
                "test-without-building",
                "-xctestrun", testRunSpecification.path,
                "-destination", destinationArgument(for: destination),
                "-derivedDataPath", derivedData.path,
                "-resultBundlePath", resultBundle.path,
                "-only-testing:\(testName)"
            ]
        )
        let process = try processRunner.start(request)
        return SharedReadingPeerHandle(role: role, process: process)
    }

    /// Xcode does not consistently forward arbitrary parent-process
    /// environment variables into an XCTest runner when launched through
    /// `test-without-building`. Keep the host native and make the boundary
    /// explicit by cloning the generated .xctestrun file for each peer. The
    /// credentials remain in a 0600, per-run temporary artifact and are
    /// removed with the other run artifacts.
    private func makeRoleTestRunSpecification(
        role: TestAccountRole,
        derivedData: URL,
        manifest: HostRunManifest,
        inviteToken: String?
    ) throws -> URL {
        let productsDirectory = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: productsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "xctestrun" }
        guard let source = candidates.sorted(by: { $0.path < $1.path }).first else {
            throw HostError.testRunSpecificationMissing(derivedData)
        }

        let credentials = role == .owner ? manifest.owner : manifest.participant
        var environment = environment(for: role, email: credentials.email, password: credentials.password, manifest: manifest, inviteToken: inviteToken)
        environment["RISHI_E2E_STAGE_LOG"] = Self.stageLogURL(
            resultBundleRoot: configuration.resultBundleRoot,
            runID: manifest.runID,
            role: role
        ).path
        let data = try Data(contentsOf: source)
        guard var root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let testKey = root.keys.first(where: { key in
                  guard let configuration = root[key] as? [String: Any] else { return false }
                  return (configuration["TestBundlePath"] as? String)?.hasSuffix(".xctest") == true
              }),
              var testConfiguration = root[testKey] as? [String: Any] else {
            throw HostError.testRunSpecificationInvalid(source)
        }

        for key in ["EnvironmentVariables", "TestingEnvironmentVariables"] {
            var values = (testConfiguration[key] as? [String: Any]) ?? [:]
            for (name, value) in environment { values[name] = value }
            testConfiguration[key] = values
        }
        root[testKey] = testConfiguration

        // Keep the clone beside the generated specification. Xcode resolves
        // `__TESTROOT__` relative to the .xctestrun file, so moving it to the
        // result directory makes the runner silently discover zero tests.
        let target = productsDirectory.appendingPathComponent(
            "\(manifest.runID)-\(role.rawValue).xctestrun"
        )
        let updated = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try updated.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    /// A non-sensitive, host-readable progress trace. It is intentionally
    /// separate from the credential manifest and contains only fixed stage
    /// names, so a forced XCTest cancellation still leaves useful evidence.
    public static func stageLogURL(
        resultBundleRoot: URL,
        runID: String,
        role: TestAccountRole
    ) -> URL {
        resultBundleRoot.appendingPathComponent("\(runID)-\(role.rawValue).stages")
    }

    private func destinationArgument(for destination: SharedReadingDestination) -> String {
        destination == .catalyst
            ? "platform=macOS,variant=Mac Catalyst"
            : "platform=iOS Simulator,id=\(configuration.simulatorID)"
    }

    private func runBounded(
        _ request: ProcessRequest,
        role: TestAccountRole,
        timeout: Duration = .seconds(120)
    ) async throws -> ProcessResult {
        let handle = try processRunner.start(request)
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask { try await handle.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                handle.cancel()
                throw HostError.processTimedOut(role: role)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func commonArguments(for destination: SharedReadingDestination, derivedData: URL) -> [String] {
        commonArguments(
            for: destination,
            derivedData: derivedData,
            sourcePackages: configuration.derivedDataRoot.appendingPathComponent("SourcePackages", isDirectory: true)
        )
    }

    private func commonArguments(
        for destination: SharedReadingDestination,
        derivedData: URL,
        sourcePackages: URL
    ) -> [String] {
        let destinationArgument = destination == .catalyst
            ? "platform=macOS,variant=Mac Catalyst"
            : "platform=iOS Simulator,id=\(configuration.simulatorID)"
        // Package sources are shared only within this host run. The host
        // prepares destinations serially under the cross-process build lock,
        // while derived data remains isolated per destination.
        return [
            "-project", configuration.projectPath.path, "-scheme", configuration.scheme,
            "-configuration", "Debug", "-destination", destinationArgument,
            "-derivedDataPath", derivedData.path,
            "-clonedSourcePackagesDirPath", sourcePackages.path,
            "-parallel-testing-enabled", "NO",
            // The shared-reading E2E does not exercise Siri/App Intents
            // metadata. Xcode Beta's localization/archive processor can
            // spend many minutes in this build-only phase, so keep it out of
            // the disposable UI-test build while leaving normal app builds
            // unchanged.
            "ENABLE_APP_INTENTS_METADATA_GENERATION=NO"
        ]
    }

    private func preflightPackageResolution() async throws {
        let root = configuration.derivedDataRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourcePackages = root.appendingPathComponent("SourcePackages", isDirectory: true)
        let buildLock = try AppleXcodeBuildLock.acquire()
        defer { try? buildLock.release() }

        for destination in [SharedReadingDestination.catalyst, .iPhone17Pro] {
            let derivedData = root.appendingPathComponent(destination.rawValue, isDirectory: true)
            try ResourcePreflight.requireSufficient(for: derivedData)
            let result = try await runBounded(ProcessRequest(
                executablePath: "/usr/bin/xcodebuild",
                arguments: ["-resolvePackageDependencies"] + commonArguments(
                    for: destination,
                    derivedData: derivedData,
                    sourcePackages: sourcePackages
                )
            ), role: .owner, timeout: .seconds(600))
            guard result.succeeded else {
                reportProcessFailure(role: .owner, result: result)
                throw HostError.processFailed(role: .owner, status: result.exitStatus)
            }
            try ResourcePreflight.requireSufficient(for: derivedData)
        }
    }

    private func environment(for role: TestAccountRole, email: String, password: String, manifest: HostRunManifest, inviteToken: String?) -> [String: String] {
        var values = configuration.rendezvousEnvironment.merging([
            "RISHI_UITEST": "1",
            "RISHI_E2E_REAL_AUTH": "1",
            "RISHI_E2E_RESET_ON_LAUNCH": "1",
            "RISHI_E2E_ROLE": role.rawValue,
            "RISHI_E2E_RUN_ID": manifest.runID,
            "RISHI_E2E_EMAIL": email,
            "RISHI_E2E_PASSWORD": password,
            "RISHI_E2E_TEST_AUTH_SECRET": ProcessInfo.processInfo.environment["RISHI_E2E_TEST_AUTH_SECRET"] ?? "",
            "RISHI_E2E_MANIFEST_PATH": role == .owner ? manifest.manifestPath : "",
            "RISHI_E2E_FIXTURE_PATH": role == .owner ? (configuration.fixturePath?.path ?? "") : ""
        ]) { _, new in new }
        if let inviteToken, !inviteToken.isEmpty {
            values["RISHI_E2E_INVITE_TOKEN"] = inviteToken
        }
        return values
    }

    public func wait(_ handle: SharedReadingPeerHandle) async throws -> ProcessResult {
        if let process = handle.process { return try await process.wait() }
        return ProcessResult(exitStatus: handle.status, stdout: "", stderr: "")
    }

    public func cancel(_ handle: SharedReadingPeerHandle) async throws {
        guard let process = handle.process else { return }
        process.cancel()
        _ = try await process.wait()
    }
}

public enum HostError: Error, LocalizedError, Equatable {
    case simulatorResetNotPermitted
    case simulatorServiceUnavailable
    case simulatorNotFound
    case derivedDataPathInUse(URL)
    case preparedDataMissing(URL)
    case testRunSpecificationMissing(URL)
    case testRunSpecificationInvalid(URL)
    case processTimedOut(role: TestAccountRole)
    case processFailed(role: TestAccountRole, status: Int32)
    case peerTimedOut(role: TestAccountRole)
    case resourcePressure(String)
    case unexpected(String)
    case cleanupFailed

    public var errorDescription: String? {
        switch self {
        case .simulatorResetNotPermitted: return "Simulator reset requires explicit permission."
        case .simulatorServiceUnavailable: return "CoreSimulatorService is unavailable; no simulator state was changed."
        case .simulatorNotFound: return "The configured device is not an available iPhone 17 Pro simulator."
        case .derivedDataPathInUse(let url): return "Derived-data path is already in use: \(url.path)"
        case .preparedDataMissing(let url): return "Prepared derived data is missing: \(url.path)"
        case .testRunSpecificationMissing(let url): return "Generated .xctestrun specification is missing under: \(url.path)"
        case .testRunSpecificationInvalid(let url): return "Generated .xctestrun specification is invalid: \(url.path)"
        case .processTimedOut(let role): return "The \(role.rawValue) Xcode operation exceeded its time limit."
        case .processFailed(let role, let status): return "The \(role.rawValue) XCTest run exited with status \(status)."
        case .peerTimedOut(let role): return "The \(role.rawValue) XCTest run exceeded its time limit."
        case .resourcePressure(let message): return "Apple E2E stopped to protect system resources: \(message)"
        case .unexpected(let message): return "Shared-reading E2E failed unexpectedly: \(message)"
        case .cleanupFailed: return "Shared-reading E2E cleanup failed."
        }
    }
}

public struct SharedReadingHost: Sendable {
    public struct Configuration: Sendable, Equatable {
        public let runID: String
        public let fixture: RealBookFixture.Manifest
        public let manifestURL: URL
        public let rendezvousURL: URL
        public let ownerDestination: SharedReadingDestination
        public let participantDestination: SharedReadingDestination
        public let inviteTimeout: Duration
        public let peerTimeout: Duration
        public let fixturePath: URL?

        public init(runID: String, fixture: RealBookFixture.Manifest, manifestURL: URL, rendezvousURL: URL? = nil, ownerDestination: SharedReadingDestination, participantDestination: SharedReadingDestination, inviteTimeout: Duration = .seconds(300), peerTimeout: Duration = .seconds(300), fixturePath: URL? = nil) {
            self.runID = runID
            self.fixture = fixture
            self.manifestURL = manifestURL
            self.rendezvousURL = rendezvousURL ?? manifestURL.appendingPathExtension("invite")
            self.ownerDestination = ownerDestination
            self.participantDestination = participantDestination
            self.inviteTimeout = inviteTimeout
            self.peerTimeout = peerTimeout
            self.fixturePath = fixturePath
        }
    }

    private let configuration: Configuration
    private let accounts: any TestAccountManaging
    private let peers: any SharedReadingPeerRunner
    private let rendezvous: any SharedReadingRendezvous
    private let fixtureProvisioner: (any FixtureBookProvisioning)?

    public init(
        configuration: Configuration,
        accounts: any TestAccountManaging,
        peers: any SharedReadingPeerRunner,
        rendezvous: any SharedReadingRendezvous = RendezvousFileStore(),
        fixtureProvisioner: (any FixtureBookProvisioning)? = nil
    ) {
        self.configuration = configuration
        self.accounts = accounts
        self.peers = peers
        self.rendezvous = rendezvous
        self.fixtureProvisioner = fixtureProvisioner
    }

    @discardableResult
    public func run(preflightAlreadyCompleted: Bool = false) async throws -> SharedReadingHostResult {
        let report = await runReport(preflightAlreadyCompleted: preflightAlreadyCompleted)
        if report.cleanupFailed { throw HostError.cleanupFailed }
        if let primaryFailure = report.primaryFailure { throw primaryFailure }
        return SharedReadingHostResult(runID: configuration.runID)
    }

    /// Runs the lifecycle without allowing a teardown failure to erase the
    /// operation failure that caused teardown to begin.
    public func runReport(preflightAlreadyCompleted: Bool = false) async -> SharedReadingRunReport {
        var owner: TestAccount?
        var participant: TestAccount?
        var ownerHandle: SharedReadingPeerHandle?
        var participantHandle: SharedReadingPeerHandle?
        var ownerCompletion: PeerCompletion?
        var primaryFailure: HostError?
        var cleanupFailedBeforeTeardown = false

        do {
            if !preflightAlreadyCompleted {
                try await accounts.preflight()
                try await peers.preflight()
            }
            try await peers.reset(target: configuration.ownerDestination)
            try await peers.reset(target: configuration.participantDestination)
            owner = try await accounts.create(role: .owner)
            participant = try await accounts.create(role: .participant)
            guard let owner, let participant else { throw HostError.cleanupFailed }
            if let fixtureProvisioner, let fixturePath = configuration.fixturePath {
                let fixture = RealBookFixture(sourceURL: fixturePath, manifest: configuration.fixture)
                _ = try await fixtureProvisioner.provision(fixture, for: owner)
                try await accounts.waitForBookUpload(owner, expectedSHA256: configuration.fixture.sha256, timeout: .seconds(60))
            }
            let manifest = HostRunManifest(
                runID: configuration.runID,
                owner: owner,
                participant: participant,
                fixture: configuration.fixture,
                manifestPath: configuration.manifestURL.path,
                ownerDestination: configuration.ownerDestination,
                participantDestination: configuration.participantDestination,
                rendezvousPath: configuration.rendezvousURL.path
            )
            try rendezvous.writeManifest(manifest, to: configuration.manifestURL)
            // Build both destinations serially before starting either XCTest
            // process. Only the already-built peer processes overlap.
            try await peers.prepare(role: .owner, account: owner, manifest: manifest, destination: configuration.ownerDestination)
            try await peers.prepare(role: .participant, account: participant, manifest: manifest, destination: configuration.participantDestination)
            ownerHandle = try await peers.launch(role: .owner, account: owner, manifest: manifest, destination: configuration.ownerDestination, inviteToken: nil)
            if fixtureProvisioner == nil, let ownerHandle {
                let completion = PeerCompletion()
                ownerCompletion = completion
                let peerRunner = peers
                Task {
                    do {
                        await completion.resolve(.finished(try await peerRunner.wait(ownerHandle)))
                    } catch {
                        await completion.resolve(.failed)
                    }
                }
                try await waitForFixtureReadiness(
                    owner: owner,
                    expectedSHA256: configuration.fixture.sha256,
                    ownerCompletion: completion
                )
            }
            let inviteToken = try await rendezvous.waitForInvite(at: configuration.rendezvousURL, timeout: configuration.inviteTimeout)
            participantHandle = try await peers.launch(role: .participant, account: participant, manifest: manifest, destination: configuration.participantDestination, inviteToken: inviteToken)
            var peerFailure: HostError?
            if let ownerCompletion {
                let result = try await ownerResult(ownerCompletion)
                if !result.succeeded {
                    reportProcessFailure(role: .owner, result: result)
                    peerFailure = .processFailed(role: .owner, status: result.exitStatus)
                }
            }
            if let participantHandle {
                let result = try await waitForPeer(participantHandle, role: .participant)
                if !result.succeeded {
                    reportProcessFailure(role: .participant, result: result)
                    if peerFailure == nil { peerFailure = .processFailed(role: .participant, status: result.exitStatus) }
                }
            }
            if let peerFailure { throw peerFailure }
        } catch let error as HostError {
            primaryFailure = error
        } catch is ProcessCleanupError {
            // A process handle only throws this error when it cannot prove
            // that its owned descendants are gone. Treat that as a cleanup
            // failure so the CLI keeps the shared build lock for recovery.
            cleanupFailedBeforeTeardown = true
        } catch {
            primaryFailure = .unexpected(String(describing: error))
        }

        // Cleanup must outlive cancellation of the host run itself. This is
        // especially important for SIGINT/SIGTERM: deleting the account,
        // verifying the deletion, and releasing the peer resources must still
        // be attempted before the interrupted run returns.
        let cleanupInputs = CleanupInputs(
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous,
            configuration: configuration,
            owner: owner,
            participant: participant,
            ownerHandle: ownerHandle,
            participantHandle: participantHandle
        )
        let cleanup = await Task.detached(priority: .utility) { @Sendable in
            await SharedReadingHost.cleanup(inputs: cleanupInputs)
        }.value

        return SharedReadingRunReport(
            runID: configuration.runID,
            primaryFailure: primaryFailure,
            cleanupFailed: cleanupFailedBeforeTeardown || cleanup.cleanupFailed
        )
    }

    private struct CleanupOutcome: Sendable {
        let cleanupFailed: Bool
    }

    private struct CleanupInputs: Sendable {
        let accounts: any TestAccountManaging
        let peers: any SharedReadingPeerRunner
        let rendezvous: any SharedReadingRendezvous
        let configuration: Configuration
        let owner: TestAccount?
        let participant: TestAccount?
        let ownerHandle: SharedReadingPeerHandle?
        let participantHandle: SharedReadingPeerHandle?
    }

    private static func cleanup(
        inputs: CleanupInputs
    ) async -> CleanupOutcome {
        let accounts = inputs.accounts
        let peers = inputs.peers
        let rendezvous = inputs.rendezvous
        let configuration = inputs.configuration
        let owner = inputs.owner
        let participant = inputs.participant
        let ownerHandle = inputs.ownerHandle
        let participantHandle = inputs.participantHandle
        var cleanupFailed = false
        // Stop any peer still running before deleting its account or removing
        // its manifest. This is essential on invite timeout/failure paths: a
        // live XCTest process must not continue using deleted credentials or
        // hold the simulator/build resources open.
        var ownerStopped = ownerHandle == nil
        var participantStopped = participantHandle == nil
        if let ownerHandle {
            do { try await peers.cancel(ownerHandle); ownerStopped = true } catch { cleanupFailed = true }
        }
        if let participantHandle {
            do { try await peers.cancel(participantHandle); participantStopped = true } catch { cleanupFailed = true }
        }
        // Delete each account independently once its own peer is stopped. A
        // failed stop must preserve that account's credentials, but must not
        // prevent cleanup of the other account.
        var accountsDeletedAndVerified = true
        if let owner, ownerStopped {
            do {
                try await accounts.delete(owner)
                try await accounts.verifyDeleted(owner)
            } catch {
                // Do not verify after a failed delete: the account may
                // still be live, and its credentials must remain
                // available for a retry or manual recovery.
                accountsDeletedAndVerified = false
                cleanupFailed = true
            }
        } else if owner != nil {
            accountsDeletedAndVerified = false
        }
        if let participant, participantStopped {
            do {
                try await accounts.delete(participant)
                try await accounts.verifyDeleted(participant)
            } catch {
                accountsDeletedAndVerified = false
                cleanupFailed = true
            }
        } else if participant != nil {
            accountsDeletedAndVerified = false
        }
        if accountsDeletedAndVerified {
            do {
                try rendezvous.removeManifest(at: configuration.manifestURL, rendezvousURL: configuration.rendezvousURL)
            } catch { cleanupFailed = true }
        }
        return CleanupOutcome(cleanupFailed: cleanupFailed)
    }

    private enum PeerWaitOutcome: Sendable {
        case finished(ProcessResult)
        case failed
        case timedOut
    }

    private func waitForFixtureReadiness(
        owner: TestAccount,
        expectedSHA256: String,
        ownerCompletion: PeerCompletion
    ) async throws {
        let accounts = accounts
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await accounts.waitForBookUpload(owner, expectedSHA256: expectedSHA256, timeout: .seconds(180))
            }
            group.addTask {
                switch try await ownerCompletion.wait() {
                case .finished(let result) where !result.succeeded:
                    throw HostError.processFailed(role: .owner, status: result.exitStatus)
                case .failed:
                    throw HostError.processFailed(role: .owner, status: -1)
                case .finished:
                    // A successful owner normally exits only after the
                    // participant completes. Keep that completion available
                    // for the final assertion without letting it beat the
                    // independent fixture-readiness operation.
                    try await Task.sleep(for: .seconds(86_400))
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func ownerResult(_ completion: PeerCompletion) async throws -> ProcessResult {
        switch try await completion.wait() {
        case .finished(let result): return result
        case .failed: throw HostError.processFailed(role: .owner, status: -1)
        }
    }

    private func waitForPeer(_ handle: SharedReadingPeerHandle, role: TestAccountRole) async throws -> ProcessResult {
        let peerRunner = peers
        let timeout = configuration.peerTimeout
        let outcome = await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: PeerWaitOutcome.self) { group in
                group.addTask {
                    do { return .finished(try await peerRunner.wait(handle)) }
                    catch { return .failed }
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    } catch {
                        return .failed
                    }
                }
                let first = await group.next() ?? .failed
                var result = first
                if case .timedOut = first {
                    do {
                        try await peerRunner.cancel(handle)
                    } catch {
                        result = .failed
                    }
                }
                group.cancelAll()
                return result
            }
        }, onCancel: {
            Task { try? await peerRunner.cancel(handle) }
        })
        switch outcome {
        case .finished(let result): return result
        case .failed: throw HostError.processFailed(role: role, status: -1)
        case .timedOut: throw HostError.peerTimedOut(role: role)
        }
    }

}

public struct SharedReadingHostResult: Sendable, Equatable {
    public let runID: String
    public init(runID: String) { self.runID = runID }
}

private actor PeerCompletion {
    enum Outcome: Sendable {
        case finished(ProcessResult)
        case failed
    }

    private var outcome: Outcome?
    private var waiters: [UUID: CheckedContinuation<Outcome, Error>] = [:]

    func resolve(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: outcome) }
    }

    func wait() async throws -> Outcome {
        if let outcome { return outcome }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: outcome)
                } else {
                    waiters[id] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

public struct SharedReadingRunReport: Sendable, Equatable {
    public let runID: String
    public let primaryFailure: HostError?
    public let cleanupFailed: Bool

    public init(runID: String, primaryFailure: HostError?, cleanupFailed: Bool) {
        self.runID = runID
        self.primaryFailure = primaryFailure
        self.cleanupFailed = cleanupFailed
    }

    public var succeeded: Bool {
        primaryFailure == nil && !cleanupFailed
    }
}

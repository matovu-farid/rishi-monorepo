import Foundation
#if canImport(Darwin)
import Darwin

// Swift imports Darwin's `sigaction` structure and C function with the same
// name, so the function is not directly spellable through the module. Bind
// the C symbol explicitly while preserving its exact Darwin ABI.
@_silgen_name("sigaction")
private func rishiDarwinSigaction(
    _ signal: Int32,
    _ action: UnsafePointer<sigaction>?,
    _ previous: UnsafeMutablePointer<sigaction>?
) -> Int32
#endif

public struct SharedReadingLiveRunEvidence: Codable, Equatable, Sendable {
    public let runID: String
    public let participantProgressSequence: Int64
    public let deletedAccountCount: Int
}

public enum SharedReadingLiveRunError: Error, LocalizedError, Equatable, Sendable {
    case missingConfiguration(String)
    case invalidProductionEndpoint
    case externalPreparedDerivedRoot
    case retainedRecoveryArtifact
    case insufficientParticipantProgress
    case cleanupIncomplete
    case liveCompositionUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let value): return "Missing required live E2E configuration: \(value)"
        case .invalidProductionEndpoint: return "RISHI_E2E_API_BASE_URL must be the canonical https://api.fidexa.org endpoint."
        case .externalPreparedDerivedRoot: return "Live E2E derived data must be owned by its run directory."
        case .retainedRecoveryArtifact: return "A retained live E2E recovery artifact must be reconciled first."
        case .insufficientParticipantProgress: return "The participant did not observe the required progress sequence."
        case .cleanupIncomplete: return "Live E2E owned-resource cleanup could not be proven."
        case .liveCompositionUnavailable: return "Live E2E production composition is not configured."
        }
    }
}

public enum SharedReadingLiveRun {
    struct SignalInstallation: Sendable {
        let cancel: @Sendable () throws -> Void
        static let none = SignalInstallation(cancel: {})
    }

    struct Dependencies: Sendable {
        let unresolvedArtifact: @Sendable (URL) throws -> Bool
        let accountPreflight: @Sendable () async throws -> Void
        let destinationPreflight: @Sendable () async throws -> Void
        let beginRun: @Sendable (String, URL) throws -> Void
        let acquireAndJournalLock: @Sendable () throws -> Void
        let preparePackages: @Sendable () async throws -> Void
        let startRelay: @Sendable () throws -> Void
        let createDisposableSimulator: @Sendable () async throws -> Void
        let runHost: @Sendable () async throws -> SharedReadingRunReport
        let participantProgress: @Sendable () -> Int64?
        let finish: @Sendable (_ succeeded: Bool, _ keepDiagnostics: Bool) async throws -> Void
        let makeRunID: @Sendable () -> String
        let installSignals: @Sendable (@escaping @Sendable () -> Void) throws -> SignalInstallation

        static func probe(
            progress: Int64 = 2,
            report: SharedReadingRunReport = .init(runID: "probe", primaryFailure: nil, cleanupFailed: false),
            _ record: @escaping @Sendable (String) -> Void
        ) -> Dependencies {
            Dependencies(
                unresolvedArtifact: { _ in record("recovery:check"); return false },
                accountPreflight: { record("account:preflight") },
                destinationPreflight: { record("destination:preflight") },
                beginRun: { _, _ in record("journal:create") },
                acquireAndJournalLock: { record("lock:acquire+journal") },
                preparePackages: { record("packages:resolve") },
                startRelay: { record("relay:start") },
                createDisposableSimulator: { record("simulator:create") },
                runHost: { record("host:run"); return report },
                participantProgress: { record("relay:progress"); return progress },
                finish: { success, keep in record("finish:\(success):\(keep)") },
                makeRunID: { "probe" },
                installSignals: { _ in .none }
            )
        }

    }

    static let validTestEnvironment: [String: String] = [
        "RISHI_E2E_ALLOW_NETWORK": "1", "RISHI_E2E_ALLOW_SIMULATOR_RESET": "1",
        "RISHI_E2E_API_BASE_URL": "https://api.fidexa.org",
        "RISHI_E2E_TEST_AUTH_SECRET": "test-secret", "RISHI_E2E_TEST_DOMAIN": "example.test",
        "RISHI_E2E_PROJECT": "/private/tmp/rishi.xcodeproj", "RISHI_E2E_FIXTURE": "/private/tmp/book.epub",
        "RISHI_E2E_IPHONE17_UDID": "source-udid",
    ]

    public static func execute(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> SharedReadingLiveRunEvidence {
        let production = try ProductionState(environment: environment)
        return try await execute(environment: environment, dependencies: production.dependencies)
    }

    public static func preflight(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let production = try ProductionState(environment: environment)
        try await preflight(environment: environment, dependencies: production.dependencies)
    }

    static func execute(environment: [String: String], dependencies: Dependencies) async throws -> SharedReadingLiveRunEvidence {
        let configuration = try validate(environment)
        if try dependencies.unresolvedArtifact(configuration.temporaryRoot) { throw SharedReadingLiveRunError.retainedRecoveryArtifact }
        try await dependencies.accountPreflight()
        try await dependencies.destinationPreflight()
        let runID = dependencies.makeRunID()
        let runRoot = configuration.temporaryRoot.appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
        try dependencies.beginRun(runID, runRoot)
        do {
            try dependencies.acquireAndJournalLock()
            try await runWithSignals(dependencies: dependencies) {
                try await dependencies.preparePackages()
            }
            try dependencies.startRelay()
            try await dependencies.createDisposableSimulator()
            let report = try await runWithSignals(dependencies: dependencies) {
                try await dependencies.runHost()
            }
            guard report.primaryFailure == nil, !report.cleanupFailed else { throw report.primaryFailure ?? SharedReadingLiveRunError.cleanupIncomplete }
            guard let progress = dependencies.participantProgress(), progress >= 2 else { throw SharedReadingLiveRunError.insufficientParticipantProgress }
            try await dependencies.finish(true, configuration.keepArtifacts)
            return SharedReadingLiveRunEvidence(runID: report.runID, participantProgressSequence: progress, deletedAccountCount: 2)
        } catch {
            try? await dependencies.finish(false, true)
            throw error
        }
    }

    static func preflight(environment: [String: String], dependencies: Dependencies) async throws {
        let configuration = try validate(environment, requireSimulatorReset: false)
        if try dependencies.unresolvedArtifact(configuration.temporaryRoot) { throw SharedReadingLiveRunError.retainedRecoveryArtifact }
        try await dependencies.accountPreflight()
        try await dependencies.destinationPreflight()
        let runID = "preflight-\(dependencies.makeRunID())"
        let root = configuration.temporaryRoot.appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
        try dependencies.beginRun(runID, root)
        do {
            try dependencies.acquireAndJournalLock()
            try await runWithSignals(dependencies: dependencies) {
                try await dependencies.preparePackages()
            }
            try await dependencies.finish(true, false)
        } catch {
            try? await dependencies.finish(false, true)
            throw error
        }
    }

    private struct ValidatedConfiguration { let temporaryRoot: URL; let keepArtifacts: Bool }

    private static func runWithSignals<T: Sendable>(
        dependencies: Dependencies,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await operation() }
        let installation: SignalInstallation
        do {
            installation = try dependencies.installSignals { task.cancel() }
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        do {
            let value = try await task.value
            try installation.cancel()
            return value
        } catch {
            task.cancel()
            _ = try? await task.value
            try? installation.cancel()
            throw error
        }
    }

    private static func validate(_ environment: [String: String], requireSimulatorReset: Bool = true) throws -> ValidatedConfiguration {
        guard environment["RISHI_E2E_ALLOW_NETWORK"] == "1" else { throw SharedReadingLiveRunError.missingConfiguration("RISHI_E2E_ALLOW_NETWORK=1") }
        if requireSimulatorReset, environment["RISHI_E2E_ALLOW_SIMULATOR_RESET"] != "1" { throw SharedReadingLiveRunError.missingConfiguration("RISHI_E2E_ALLOW_SIMULATOR_RESET=1") }
        guard environment["RISHI_E2E_PREPARED_DERIVED_ROOT"] == nil else { throw SharedReadingLiveRunError.externalPreparedDerivedRoot }
        guard let rawURL = environment["RISHI_E2E_API_BASE_URL"], let url = URL(string: rawURL), url.absoluteString == rawURL,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.fidexa.org",
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              url.port == nil, url.user == nil, url.password == nil else { throw SharedReadingLiveRunError.invalidProductionEndpoint }
        for key in ["RISHI_E2E_TEST_AUTH_SECRET", "RISHI_E2E_TEST_DOMAIN", "RISHI_E2E_PROJECT", "RISHI_E2E_FIXTURE", "RISHI_E2E_IPHONE17_UDID"] {
            guard let value = environment[key], !value.isEmpty else { throw SharedReadingLiveRunError.missingConfiguration(key) }
        }
        let root = URL(fileURLWithPath: environment["RISHI_E2E_TEMP_ROOT"] ?? NSTemporaryDirectory(), isDirectory: true)
        guard root.path.hasPrefix("/"), root.standardizedFileURL.path == root.path else { throw SharedReadingLiveRunError.missingConfiguration("canonical RISHI_E2E_TEMP_ROOT") }
        return ValidatedConfiguration(temporaryRoot: root, keepArtifacts: environment["RISHI_E2E_KEEP_ARTIFACTS"] == "1")
    }
}

private final class ProductionState: @unchecked Sendable {
    private let environment: [String: String]
    private let baseURL: URL
    private let projectURL: URL
    private let fixtureURL: URL
    private let sourceSimulatorID: String
    private let accountConfiguration: TestAccountClient.Configuration
    private let processRunner = FoundationProcessRunner()
    private var runID = ""
    private var runRoot: URL?
    private var journal: SharedReadingRecoveryJournal?
    private var preparedLock: SharedReadingPreparedBuildLock?
    private var relay: RendezvousRelayServer?
    private var relayConfiguration: RendezvousRelayConfiguration?
    private var runtimeIdentifier: String?
    private var simulator: OwnedSimulatorDevice?
    private var host: SharedReadingHost?
    private var hostRan = false
    private let artifactLock = NSLock()
    private var reservedSecretArtifacts: Set<String> = []

    init(environment: [String: String]) throws {
        self.environment = environment
        guard let baseURL = URL(string: environment["RISHI_E2E_API_BASE_URL"] ?? ""),
              let project = environment["RISHI_E2E_PROJECT"],
              let fixture = environment["RISHI_E2E_FIXTURE"],
              let simulator = environment["RISHI_E2E_IPHONE17_UDID"] else {
            throw SharedReadingLiveRunError.missingConfiguration("production dependencies")
        }
        self.baseURL = baseURL
        self.projectURL = URL(fileURLWithPath: project)
        self.fixtureURL = URL(fileURLWithPath: fixture)
        self.sourceSimulatorID = simulator
        self.accountConfiguration = .init(
            baseURL: baseURL,
            testAuthSecret: environment["RISHI_E2E_TEST_AUTH_SECRET"] ?? "",
            testDomain: environment["RISHI_E2E_TEST_DOMAIN"] ?? ""
        )
    }

    var dependencies: SharedReadingLiveRun.Dependencies {
        .init(
            unresolvedArtifact: { root in try SharedReadingRecoveryJournal.unresolvedArtifact(in: root) != nil },
            accountPreflight: { [self] in try await TestAccountClient(configuration: accountConfiguration).preflight() },
            destinationPreflight: { [self] in try await preflightDestination() },
            beginRun: { [self] runID, root in try begin(runID: runID, root: root) },
            acquireAndJournalLock: { [self] in try acquireLock() },
            preparePackages: { [self] in try await preparePackages() },
            startRelay: { [self] in try startRelay() },
            createDisposableSimulator: { [self] in try await createSimulator() },
            runHost: { [self] in try await runHost() },
            participantProgress: { [self] in relay?.participantProgressSequence(runID: runID) },
            finish: { [self] success, keep in try await finish(success: success, keepDiagnostics: keep) },
            makeRunID: { UUID().uuidString.lowercased() },
            installSignals: { cancel in
                try LiveRunSignalHandler.install(cancel: cancel)
            }
        )
    }

    private func preflightDestination() async throws {
        let root = URL(fileURLWithPath: environment["RISHI_E2E_TEMP_ROOT"] ?? NSTemporaryDirectory(), isDirectory: true)
        let runner = XCTestPeerProcessRunner(
            configuration: .init(
                projectPath: projectURL, simulatorID: sourceSimulatorID,
                derivedDataRoot: root, resultBundleRoot: root
            ),
            processRunner: processRunner
        )
        try await runner.preflight()
        let inventory = try await processRunner.run(.init(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "-j"]
        ))
        guard inventory.succeeded,
              let data = inventory.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["devices"] as? [String: [[String: Any]]],
              let runtime = groups.first(where: { _, devices in
                  devices.contains { ($0["udid"] as? String) == sourceSimulatorID && ($0["name"] as? String) == "iPhone 17 Pro" }
              })?.key else {
            throw HostError.simulatorNotFound
        }
        runtimeIdentifier = runtime
    }

    private func begin(runID: String, root: URL) throws {
        // Validate and hash the configured fixture before creating the
        // ownership artifact. A malformed path must not manufacture a stale
        // recovery run that never acquired resources.
        _ = try RealBookFixtures.resolve(role: .owner, path: fixtureURL)
        self.runID = runID
        self.runRoot = root
        journal = try SharedReadingRecoveryJournal(url: root.appendingPathComponent("recovery.json"), runID: runID)
    }

    private func acquireLock() throws {
        guard let journal else { throw SharedReadingLiveRunError.cleanupIncomplete }
        preparedLock = try SharedReadingHost.prepareBuildLock(
            recorder: journal,
            acquire: { try AppleXcodeBuildLock.acquire(environment: self.environment) }
        )
    }

    private func preparePackages() async throws {
        guard let runRoot, let journal, let preparedLock else { throw SharedReadingLiveRunError.cleanupIncomplete }
        let runner = FoundationProcessRunner(recorder: journal)
        try await PackageDependencyPreparer(processRunner: runner).preparePackageDependencies(
            project: projectURL,
            derivedDataRoot: runRoot.appendingPathComponent("derived", isDirectory: true),
            whileHolding: try preparedLock.borrowedLock()
        )
    }

    private func startRelay() throws {
        guard let journal else { throw SharedReadingLiveRunError.cleanupIncomplete }
        let relay = RendezvousRelayServer(processRecorder: journal)
        let configuration = try relay.start()
        _ = try relay.reserveRegistration(
            runID: runID, role: .owner, kind: .runner,
            bundleIdentifier: "org.fidexa.rishiUITests"
        )
        _ = try relay.reserveRegistration(
            runID: runID, role: .owner, kind: .app,
            bundleIdentifier: "org.fidexa.rishi"
        )
        self.relay = relay
        relayConfiguration = configuration
    }

    private func createSimulator() async throws {
        guard let runtimeIdentifier, let journal else { throw SharedReadingLiveRunError.cleanupIncomplete }
        let intent = OwnedSimulatorDevice(
            udid: nil,
            name: "rishi-e2e-\(runID)-iPhone 17 Pro",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: runtimeIdentifier
        )
        try journal.recordOwnedSimulatorDevice(intent)
        let runner = FoundationProcessRunner(recorder: journal)
        let create = try await runner.run(.init(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "create", intent.name, intent.deviceTypeIdentifier, intent.runtimeIdentifier]
        ))
        guard create.succeeded else { throw HostError.simulatorServiceUnavailable }
        let udid = create.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: udid) != nil else { throw HostError.simulatorServiceUnavailable }
        let realized = OwnedSimulatorDevice(
            udid: udid, name: intent.name,
            deviceTypeIdentifier: intent.deviceTypeIdentifier,
            runtimeIdentifier: intent.runtimeIdentifier
        )
        try journal.recordRealizedSimulatorDevice(realized, replacingIntent: intent)
        simulator = realized
        let boot = try await runner.run(.init(executablePath: "/usr/bin/xcrun", arguments: ["simctl", "boot", udid]))
        guard boot.succeeded || boot.stderr.contains("current state: Booted") else { throw HostError.simulatorServiceUnavailable }
    }

    private func runHost() async throws -> SharedReadingRunReport {
        guard let runRoot, let journal, let preparedLock, let relay, let relayConfiguration,
              let simulatorID = simulator?.udid else { throw SharedReadingLiveRunError.cleanupIncomplete }
        let runnerNonce = try registrationNonce(in: relay, kind: .runner)
        let appNonce = try registrationNonce(in: relay, kind: .app)
        let derived = runRoot.appendingPathComponent("derived", isDirectory: true)
        let results = runRoot.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let peerRunner = XCTestPeerProcessRunner(
            configuration: .init(
                projectPath: projectURL, simulatorID: simulatorID,
                derivedDataRoot: derived, resultBundleRoot: results,
                allowSimulatorReset: true, fixturePath: fixtureURL,
                rendezvousEnvironment: relayConfiguration.environment,
                catalystRegistration: .init(runnerNonce: runnerNonce, appNonce: appNonce)
            ),
            processRunner: FoundationProcessRunner(recorder: journal),
            recoveryJournal: journal,
            secretArtifactDidReserve: { [self] relativePath in
                _ = artifactLock.withLock { reservedSecretArtifacts.insert(relativePath) }
            }
        )
        let fixture = try RealBookFixtures.resolve(role: .owner, path: fixtureURL)
        let accounts = TestAccountClient(configuration: accountConfiguration, lifecycleRecorder: journal)
        let host = try SharedReadingHost.withPreparedBuildLockForHost(
            recoveryJournal: journal,
            prepare: { preparedLock },
            makeHost: { prepared in
                try SharedReadingHost(
                    configuration: .init(
                        runID: self.runID, fixture: fixture.manifest,
                        manifestURL: runRoot.appendingPathComponent("manifest.json"),
                        ownerDestination: .catalyst, participantDestination: .iPhone17Pro,
                        fixturePath: self.fixtureURL
                    ),
                    accounts: accounts, peers: peerRunner, rendezvous: relay,
                    fixtureProvisioner: FixtureBookProvisioner(configuration: .init(baseURL: self.baseURL)),
                    preAccountCleanup: { try await self.cleanupOwnedResources() },
                    preparedBuildLock: prepared
                )
            }
        )
        self.host = host
        // The prepared capability is owned by the host from this point. Set
        // this before awaiting so cancellation cannot try to borrow it again.
        hostRan = true
        let report = try await host.runReport(preflightAlreadyCompleted: true)
        return report
    }

    private func registrationNonce(in relay: RendezvousRelayServer, kind: PendingCatalystLaunch.Kind) throws -> String {
        // Reservations are intentionally generated only by the relay. The
        // production runner recreates neither token; expose it through a
        // one-shot lookup scoped to this in-process composition.
        try relay.reservedNonce(runID: runID, role: .owner, kind: kind)
    }

    private func cleanupOwnedResources() async throws {
        guard let journal else { throw SharedReadingLiveRunError.cleanupIncomplete }
        for launch in relay?.registeredCatalystLaunches() ?? [] {
            guard let identity = launch.registeredIdentity else {
                // A launch intent without its callback cannot prove which
                // process, if any, reached application code. Keep the exact
                // journal intent and lock for recovery rather than guessing.
                throw SharedReadingLiveRunError.cleanupIncomplete
            }
            try await SharedReadingRecoveryJournal.recoverProcesses(
                [identity], liveIdentity: ProcessIdentityReader.identity(for:),
                signal: { pid, signal in _ = Darwin.kill(pid, signal) },
                sleep: { try await Task.sleep(for: $0) }
            )
            guard ProcessIdentityReader.identity(for: identity.pid) != identity else {
                throw SharedReadingLiveRunError.cleanupIncomplete
            }
            try journal.recordVerifiedCatalystLaunchAbsence(launch)
        }
        if let simulator, let udid = simulator.udid {
            let runner = FoundationProcessRunner(recorder: journal)
            _ = try await runner.run(.init(executablePath: "/usr/bin/xcrun", arguments: ["simctl", "shutdown", udid]))
            let deleted = try await runner.run(.init(executablePath: "/usr/bin/xcrun", arguments: ["simctl", "delete", udid]))
            guard deleted.succeeded else { throw SharedReadingLiveRunError.cleanupIncomplete }
            try journal.recordVerifiedSimulatorDeletion(simulator)
            self.simulator = nil
        }
        try removeSecretSpecifications(journal: journal)
        try removeStagedFixtures()
    }

    private func removeSecretSpecifications(journal: SharedReadingRecoveryJournal) throws {
        guard let runRoot else { return }
        let reservations = artifactLock.withLock { reservedSecretArtifacts }
        for relative in reservations.sorted() {
            let url = runRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw SharedReadingLiveRunError.cleanupIncomplete }
            try journal.recordVerifiedSecretArtifactDeletion(relativePath: relative)
        }
    }

    private func removeStagedFixtures() throws {
        let group = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent("group.org.fidexa.rishi", isDirectory: true)
        for fileExtension in ["pdf", "epub"] {
            let url = group.appendingPathComponent("rishi-e2e-fixture.\(fileExtension)")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw SharedReadingLiveRunError.cleanupIncomplete }
        }
    }

    private func finish(success: Bool, keepDiagnostics: Bool) async throws {
        relay?.stop()
        guard let journal, let runRoot else { return }
        if !hostRan, let preparedLock {
            let lock = try preparedLock.borrowedLock()
            if success {
                try lock.release()
                try journal.recordVerifiedBuildLockRelease(lock.ownership)
            } else {
                _ = lock.transferToRecovery()
                return
            }
        }
        guard success else { return }
        let derived = runRoot.appendingPathComponent("derived", isDirectory: true)
        if FileManager.default.fileExists(atPath: derived.path) { try FileManager.default.removeItem(at: derived) }
        guard !FileManager.default.fileExists(atPath: derived.path) else { throw SharedReadingLiveRunError.cleanupIncomplete }
        if keepDiagnostics {
            try journal.finalizeAfterSuccessfulCleanup()
            try verifyRetainedDiagnosticsOnly(in: runRoot)
        } else {
            let results = runRoot.appendingPathComponent("results", isDirectory: true)
            if FileManager.default.fileExists(atPath: results.path) { try FileManager.default.removeItem(at: results) }
            try journal.finalizeAndRemoveEmptyRunDirectory()
            guard !FileManager.default.fileExists(atPath: runRoot.path) else { throw SharedReadingLiveRunError.cleanupIncomplete }
        }
    }

    private func verifyRetainedDiagnosticsOnly(in runRoot: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: runRoot, includingPropertiesForKeys: nil)
        guard children.allSatisfy({ $0.lastPathComponent == "results" }) else {
            throw SharedReadingLiveRunError.cleanupIncomplete
        }
        if let enumerator = FileManager.default.enumerator(at: runRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "xctestrun" {
                throw SharedReadingLiveRunError.cleanupIncomplete
            }
        }
    }
}

enum LiveRunSignalHandler {
    struct System: @unchecked Sendable {
        let ignore: @Sendable (Int32) throws -> @Sendable () throws -> Void
        let makeSource: @Sendable (
            Int32,
            @escaping @Sendable () -> Void
        ) -> @Sendable () -> Void

        static let live = System(
            ignore: { signalNumber in
                #if canImport(Darwin)
                var ignored = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                sigemptyset(&ignored.sa_mask)
                ignored.sa_flags = 0
                var previous = sigaction()
                guard rishiDarwinSigaction(signalNumber, &ignored, &previous) == 0 else {
                    throw ResourcePreflightError("Could not install live E2E signal disposition")
                }
                let disposition = SignalDisposition(previous)
                return {
                    var previous = disposition.value
                    guard rishiDarwinSigaction(signalNumber, &previous, nil) == 0 else {
                        throw ResourcePreflightError("Could not restore live E2E signal disposition")
                    }
                }
                #else
                return {}
                #endif
            },
            makeSource: { signalNumber, cancel in
                #if canImport(Darwin)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
                source.setEventHandler(handler: cancel)
                source.resume()
                return { source.cancel() }
                #else
                return {}
                #endif
            }
        )
    }

    static func install(
        cancel: @escaping @Sendable () -> Void,
        system: System = .live
    ) throws -> SharedReadingLiveRun.SignalInstallation {
        #if canImport(Darwin)
        let state = SignalRestorationState()
        do {
            for signalNumber in [SIGINT, SIGTERM] {
                let restore = try system.ignore(signalNumber)
                let cancelSource = system.makeSource(signalNumber, cancel)
                state.append(cancelSource: cancelSource, restore: restore)
            }
        } catch {
            try? state.cancel()
            throw error
        }
        return .init(cancel: { try state.cancel() })
        #else
        return .none
        #endif
    }

    #if canImport(Darwin)
    private final class SignalDisposition: @unchecked Sendable {
        let value: sigaction
        init(_ value: sigaction) { self.value = value }
    }
    #endif

    private final class SignalRestorationState: @unchecked Sendable {
        private struct Action: Sendable {
            let cancelSource: @Sendable () -> Void
            let restore: @Sendable () throws -> Void
        }

        private let lock = NSLock()
        private var actions: [Action] = []
        private var cancelled = false

        func append(
            cancelSource: @escaping @Sendable () -> Void,
            restore: @escaping @Sendable () throws -> Void
        ) {
            lock.withLock { actions.append(.init(cancelSource: cancelSource, restore: restore)) }
        }

        func cancel() throws {
            let pending = lock.withLock { () -> [Action] in
                guard !cancelled else { return [] }
                cancelled = true
                return actions.reversed()
            }
            var firstError: Error?
            for action in pending {
                action.cancelSource()
                do { try action.restore() } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
}

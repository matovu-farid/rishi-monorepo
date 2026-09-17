import Foundation
import RishiE2EHost
#if canImport(Darwin)
import Darwin
#endif

@main
struct RishiE2EHostCLI {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }
        let preflightOnly = arguments.contains("--preflight")
        guard environment["RISHI_E2E_ALLOW_NETWORK"] == "1" else {
            throw CLIError.missing("RISHI_E2E_ALLOW_NETWORK=1")
        }

        let baseURL = try requiredURL(environment, key: "RISHI_E2E_API_BASE_URL")
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host?.lowercased() == "api.fidexa.org",
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.port == nil,
              baseURL.user == nil,
              baseURL.password == nil else {
            throw CLIError.invalidProductionEndpoint
        }
        let accountClient = TestAccountClient(configuration: .init(
            baseURL: baseURL,
            testAuthSecret: try required(environment, key: "RISHI_E2E_TEST_AUTH_SECRET"),
            testDomain: try required(environment, key: "RISHI_E2E_TEST_DOMAIN")
        ))
        if let cleanupArgument = arguments.first(where: { $0.hasPrefix("--cleanup-manifest=") }) {
            let path = String(cleanupArgument.dropFirst("--cleanup-manifest=".count))
            try await cleanupManifest(at: URL(fileURLWithPath: path), with: accountClient)
            return
        }

        let (fixture, fixtureURL) = try resolveFixture(environment)
        let simulatorID = try required(environment, key: "RISHI_E2E_IPHONE17_UDID")
        let projectPath = URL(fileURLWithPath: try required(environment, key: "RISHI_E2E_PROJECT"), isDirectory: false)
        guard FileManager.default.isReadableFile(atPath: projectPath.path) else {
            throw CLIError.invalidPath("RISHI_E2E_PROJECT")
        }
        let runID = UUID().uuidString.lowercased()
        let runRoot = URL(fileURLWithPath: environment["RISHI_E2E_TEMP_ROOT"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
        try enforceRetainedArtifactLimit(
            in: runRoot.deletingLastPathComponent(),
            environment: environment
        )
        let allowReset = environment["RISHI_E2E_ALLOW_SIMULATOR_RESET"] == "1"
        let preparedDerivedRoot = environment["RISHI_E2E_PREPARED_DERIVED_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let derivedDataRoot = preparedDerivedRoot ?? runRoot.appendingPathComponent("derived", isDirectory: true)
        let usePreparedProducts = preparedDerivedRoot != nil
        let resultBundleRoot = runRoot.appendingPathComponent("results", isDirectory: true)
        let peerConfiguration = XCTestPeerProcessRunner.Configuration(
            projectPath: projectPath,
            simulatorID: simulatorID,
            derivedDataRoot: derivedDataRoot,
            resultBundleRoot: resultBundleRoot,
            allowSimulatorReset: allowReset,
            fixturePath: nil,
            usePreparedProducts: usePreparedProducts
        )
        let peerPreflightRunner = XCTestPeerProcessRunner(configuration: peerConfiguration)
        var keepBuildLockForRecovery = false
        // Check resources, Xcode, and the exact simulator before creating any
        // run artifacts, starting a relay, or taking the global build lock.
        // An unsafe machine must not accumulate state on each rejected
        // invocation.
        try await accountClient.preflight()
        try await peerPreflightRunner.preflight()
        if preflightOnly {
            print("Shared-reading E2E preflight passed for Xcode, resources, package resolution, project, and iPhone 17 Pro.")
            return
        }

        let buildLock = try AppleXcodeBuildLock.acquire()
        defer {
            if !keepBuildLockForRecovery { try? buildLock.release() }
        }
        let relay = RendezvousRelayServer()
        let relayConfiguration = try relay.start()
        defer { relay.stop() }
        let peerRunner = XCTestPeerProcessRunner(configuration: .init(
            projectPath: projectPath,
            simulatorID: simulatorID,
            derivedDataRoot: derivedDataRoot,
            resultBundleRoot: resultBundleRoot,
            allowSimulatorReset: allowReset,
            fixturePath: nil,
            rendezvousEnvironment: relayConfiguration.environment,
            usePreparedProducts: usePreparedProducts
        ))

        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        var runCompleted = false
        defer {
            removeStagedFixture(for: fixtureURL)
            if environment["RISHI_E2E_KEEP_ARTIFACTS"] != "1" {
                if runCompleted {
                    do { try FileManager.default.removeItem(at: runRoot) }
                    catch { FileHandle.standardError.write(Data("Could not remove E2E artifacts at \(runRoot.path): \(error)\n".utf8)) }
                } else {
                    FileHandle.standardError.write(Data("Preserving E2E artifacts after an incomplete run: \(runRoot.path)\n".utf8))
                }
            }
        }
        let manifestURL = runRoot.appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(at: resultBundleRoot, withIntermediateDirectories: true)
        let host = SharedReadingHost(
            configuration: .init(
                runID: runID,
                fixture: fixture,
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro,
                fixturePath: fixtureURL
            ),
            accounts: accountClient,
            peers: peerRunner,
            rendezvous: relay,
            fixtureProvisioner: FixtureBookProvisioner(configuration: .init(baseURL: baseURL))
        )
        let runTask = Task {
            await host.runReport(preflightAlreadyCompleted: true)
        }
        let signalSources = installRunCancellationSignals(task: runTask)
        defer { signalSources.forEach { $0.cancel() } }
        do {
            let report = try await withThrowingTaskGroup(of: SharedReadingRunReport.self) { group in
                group.addTask { await runTask.value }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .seconds(5))
                        do {
                            try ResourcePreflight.requireSufficient(for: runRoot)
                        } catch let error as ResourcePreflightError {
                            runTask.cancel()
                            throw HostError.resourcePressure(error.message)
                        }
                    }
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard report.succeeded else {
                if report.cleanupFailed { keepBuildLockForRecovery = true }
                if let primaryFailure = report.primaryFailure {
                    FileHandle.standardError.write(Data("Shared-reading primary failure: \(primaryFailure.localizedDescription)\n".utf8))
                }
                if report.cleanupFailed {
                    FileHandle.standardError.write(Data("Shared-reading cleanup failure: recovery artifacts were retained.\n".utf8))
                }
                throw report.primaryFailure ?? .cleanupFailed
            }
            runCompleted = true
            print("Shared-reading E2E completed: \(report.runID)")
        } catch {
            runTask.cancel()
            // The host performs peer/account/manifest cleanup in its own
            // uncancelled phase. Do not release the shared build lock until
            // that phase has returned; otherwise a second run could start
            // while the cancelled XCTest process still owns resources.
            let report = await runTask.value
            // A cleanup failure means an owned process, account, or manifest
            // may still require recovery. Keep the shared build lock so a
            // second run cannot collide with retained derived-data state.
            if report.cleanupFailed {
                keepBuildLockForRecovery = true
            }
            if let primaryFailure = report.primaryFailure {
                FileHandle.standardError.write(Data("Shared-reading primary failure: \(primaryFailure.localizedDescription)\n".utf8))
            }
            if report.cleanupFailed {
                FileHandle.standardError.write(Data("Shared-reading cleanup failure: recovery artifacts were retained.\n".utf8))
            }
            throw error
        }
    }

    private static func removeStagedFixture(for fixtureURL: URL?) {
        let groupURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent("group.org.fidexa.rishi", isDirectory: true)
        // These are the only two filenames reserved by the E2E harness. A
        // previous run may have used the other format and failed before its
        // normal teardown, so clean both exact paths without touching the
        // user's library or any arbitrary App Group content.
        let extensions = Set(["pdf", "epub"] + (fixtureURL.map { [$0.pathExtension.lowercased()] } ?? []))
        for fileExtension in extensions {
            let stagedURL = groupURL.appendingPathComponent(
                "rishi-e2e-fixture.\(fileExtension)",
                isDirectory: false
            )
            try? FileManager.default.removeItem(at: stagedURL)
        }
    }

    private static let usage = """
    rishi-e2e-host — native Swift shared-reading E2E runner

    Usage:
      swift run rishi-e2e-host [--preflight]
      swift run rishi-e2e-host --help

    The runner creates two disposable accounts, imports one supplied PDF or
    EPUB through the Apple UI, runs Catalyst plus iPhone 17 Pro peers, and
    deletes and verifies both accounts during cleanup.

    --cleanup-manifest=PATH
                 Delete the generated test accounts named by an incomplete
                 run manifest. This uses only the gated email cleanup route;
                 it does not build, launch Xcode, or contact CoreSimulator.
    --preflight  Validate configuration, resources, Xcode, package resolution,
                 simulator, and the gated account route without creating
                 accounts or retaining build state.
    --help       Print this help without reading network credentials or
                 contacting Xcode/CoreSimulator.
    """

    private static func required(_ environment: [String: String], key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else { throw CLIError.missing(key) }
        return value
    }

    private static func requiredURL(_ environment: [String: String], key: String) throws -> URL {
        let value = try required(environment, key: key)
        guard let url = URL(string: value), url.scheme != nil else { throw CLIError.invalidURL(key) }
        return url
    }

    private static func cleanupManifest(at url: URL, with client: TestAccountClient) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CLIError.invalidPath("--cleanup-manifest")
        }
        let data = try Data(contentsOf: url)
        let emails: [String]
        if let manifest = try? JSONDecoder().decode(RendezvousManifest.self, from: data) {
            emails = [manifest.ownerEmail, manifest.participantEmail]
        } else if let manifest = try? JSONDecoder().decode(PersistedHostManifest.self, from: data) {
            // Interrupted runs persist HostRunManifest's redacted shape:
            // owner/participant objects contain role and email, while
            // credentials are intentionally absent. Recovery must support
            // that exact file, not just the smaller relay manifest.
            emails = [manifest.owner.email, manifest.participant.email]
        } else {
            throw CLIError.invalidManifest(url)
        }

        var failures: [String] = []
        for email in Set(emails) {
            do {
                try await client.deleteProvisionedAccount(email: email)
            } catch {
                failures.append("\(email): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw CLIError.cleanupFailed(failures.joined(separator: "; "))
        }
        print("Cleaned up shared-reading test accounts from \(url.lastPathComponent).")
    }

    private struct PersistedHostManifest: Decodable {
        struct Account: Decodable {
            let email: String
        }

        let owner: Account
        let participant: Account
    }

    private static func resolveFixture(_ environment: [String: String]) throws -> (RealBookFixture.Manifest, URL) {
        if let explicit = environment["RISHI_E2E_FIXTURE"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            return (try RealBookFixtures.resolve(role: .owner, path: url).manifest, url)
        }

        let requestedFormat = environment["RISHI_E2E_FIXTURE_FORMAT"]
            .flatMap { RealBookFormat(rawValue: $0.lowercased()) }
        if environment["RISHI_E2E_FIXTURE_FORMAT"] != nil && requestedFormat == nil {
            throw CLIError.invalidFixtureFormat
        }

        let configured: [(RealBookFormat, String)] = [
            (.pdf, RealBookFixtures.pdfEnvironmentKey),
            (.epub, RealBookFixtures.epubEnvironmentKey),
        ].compactMap { format, key in
            guard let path = environment[key], !path.isEmpty else { return nil }
            return (format, path)
        }
        let candidates = requestedFormat.map { format in configured.filter { $0.0 == format } } ?? configured
        guard candidates.count == 1, let (format, path) = candidates.first else {
            if candidates.isEmpty {
                throw CLIError.missing("RISHI_E2E_FIXTURE or one of the format-specific fixture variables")
            }
            throw CLIError.ambiguousFixture
        }
        let url = URL(fileURLWithPath: path)
        return (try RealBookFixtures.resolve(role: .owner, format: format, path: url).manifest, url)
    }

    private static func enforceRetainedArtifactLimit(
        in directory: URL,
        environment: [String: String]
    ) throws {
        let configured = environment["RISHI_E2E_MAX_RETAINED_RUNS"]
            .flatMap(Int.init)
            ?? 3
        let maximum = max(1, configured)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let retained = entries.filter { url in
            guard url.lastPathComponent.hasPrefix("rishi-shared-reading-"),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                return false
            }
            return true
        }
        guard retained.count < maximum else {
            throw CLIError.tooManyRetainedArtifacts(directory: directory, count: retained.count, maximum: maximum)
        }
    }

    private static func installRunCancellationSignals<Success: Sendable, Failure: Error>(
        task: Task<Success, Failure>
    ) -> [DispatchSourceSignal] {
        #if canImport(Darwin)
        return [SIGTERM, SIGINT].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
            source.setEventHandler {
                task.cancel()
            }
            source.resume()
            return source
        }
        #else
        return []
        #endif
    }
}

private enum CLIError: Error, LocalizedError {
    case missing(String)
    case invalidURL(String)
    case invalidPath(String)
    case invalidProductionEndpoint
    case invalidFixtureFormat
    case ambiguousFixture
    case invalidManifest(URL)
    case cleanupFailed(String)
    case tooManyRetainedArtifacts(directory: URL, count: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .missing(let key): return "Missing required E2E setting: \(key)"
        case .invalidURL(let key): return "Invalid URL in E2E setting: \(key)"
        case .invalidPath(let key): return "Path in E2E setting is not readable: \(key)"
        case .invalidProductionEndpoint: return "RISHI_E2E_API_BASE_URL must be the canonical https://api.fidexa.org endpoint."
        case .invalidFixtureFormat: return "RISHI_E2E_FIXTURE_FORMAT must be pdf or epub."
        case .ambiguousFixture: return "Multiple fixtures are configured; choose one with RISHI_E2E_FIXTURE or RISHI_E2E_FIXTURE_FORMAT."
        case .invalidManifest(let url): return "Could not decode the shared-reading E2E manifest: \(url.path)"
        case .cleanupFailed(let details): return "Shared-reading test-account cleanup failed: \(details)"
        case .tooManyRetainedArtifacts(let directory, let count, let maximum):
            return "Too many retained Apple E2E artifact directories in \(directory.path) (\(count); maximum \(maximum)). Remove old rishi-shared-reading-* runs explicitly before retrying."
        }
    }
}

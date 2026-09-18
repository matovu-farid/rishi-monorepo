import Foundation
import RishiE2EHost

@main
struct RishiE2EHostCLI {
    private enum Route: Equatable {
        case help
        case preflight
        case recovery(URL)
        case execute
    }

    private struct RecoveryConfiguration {
        let accountClient: TestAccountClient
        let temporaryRoot: URL
        let buildLockURL: URL
    }

    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        switch try route(arguments: Array(CommandLine.arguments.dropFirst())) {
        case .help:
            print(usage)
        case .preflight:
            try await SharedReadingLiveRun.preflight(environment: environment)
            print("Shared-reading E2E preflight passed.")
        case .recovery(let artifactURL):
            let configuration = try recoveryConfiguration(environment: environment)
            try await SharedReadingRecoveryJournal.recover(
                at: artifactURL,
                temporaryRoot: configuration.temporaryRoot,
                configuredBuildLockURL: configuration.buildLockURL,
                accountClient: configuration.accountClient
            )
            print("Shared-reading E2E recovery completed.")
        case .execute:
            let evidence = try await SharedReadingLiveRun.execute(environment: environment)
            printEvidence(evidence)
        }
    }

    private static func route(arguments: [String]) throws -> Route {
        if arguments.contains("--help") || arguments.contains("-h") {
            return .help
        }
        if arguments.isEmpty {
            return .execute
        }
        if arguments == ["--preflight"] {
            return .preflight
        }
        if arguments.count == 1,
           let argument = arguments.first,
           argument.hasPrefix("--cleanup-manifest=") {
            let path = String(argument.dropFirst("--cleanup-manifest=".count))
            guard !path.isEmpty,
                  path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                throw CLIError.invalidPath("--cleanup-manifest")
            }
            return .recovery(URL(fileURLWithPath: path))
        }
        throw CLIError.invalidArguments
    }

    private static func recoveryConfiguration(
        environment: [String: String]
    ) throws -> RecoveryConfiguration {
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

        let temporaryRoot = try canonicalDirectoryURL(
            environment["RISHI_E2E_TEMP_ROOT"] ?? NSTemporaryDirectory(),
            key: "RISHI_E2E_TEMP_ROOT"
        )
        let buildLockURL = try canonicalDirectoryURL(
            environment["RISHI_APPLE_XCODE_BUILD_LOCK_PATH"]
                ?? "/private/tmp/rishi-apple-xcode-build.lock",
            key: "RISHI_APPLE_XCODE_BUILD_LOCK_PATH"
        )
        guard buildLockURL.path != "/" else {
            throw CLIError.invalidPath("RISHI_APPLE_XCODE_BUILD_LOCK_PATH")
        }

        return RecoveryConfiguration(
            accountClient: TestAccountClient(configuration: .init(
                baseURL: baseURL,
                testAuthSecret: try required(environment, key: "RISHI_E2E_TEST_AUTH_SECRET"),
                testDomain: try required(environment, key: "RISHI_E2E_TEST_DOMAIN")
            )),
            temporaryRoot: temporaryRoot,
            buildLockURL: buildLockURL
        )
    }

    private static func printEvidence(_ evidence: SharedReadingLiveRunEvidence) {
        print("Shared-reading E2E completed: \(evidence.runID)")
        print("Participant observed sequence: \(evidence.participantProgressSequence)")
        print("Temporary accounts deleted and verified: \(evidence.deletedAccountCount)")
    }

    private static func required(_ environment: [String: String], key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw CLIError.missing(key)
        }
        return value
    }

    private static func requiredURL(_ environment: [String: String], key: String) throws -> URL {
        let value = try required(environment, key: key)
        guard let url = URL(string: value), url.absoluteString == value else {
            throw CLIError.invalidURL(key)
        }
        return url
    }

    private static func canonicalDirectoryURL(_ path: String, key: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw CLIError.invalidPath(key)
        }
        let suppliedPath = trimmed == "/" || !trimmed.hasSuffix("/")
            ? trimmed
            : String(trimmed.dropLast())
        let components = (suppliedPath as NSString).pathComponents
        guard suppliedPath.utf8.count < 1_024,
              !suppliedPath.contains("//"),
              !components.contains("."),
              !components.contains(".."),
              URL(fileURLWithPath: suppliedPath, isDirectory: true).path == suppliedPath else {
            throw CLIError.invalidPath(key)
        }
        return URL(fileURLWithPath: suppliedPath, isDirectory: true)
    }

    private static let usage = """
    rishi-e2e-host — native Swift shared-reading E2E runner

    Usage:
      swift run rishi-e2e-host
      swift run rishi-e2e-host --preflight
      swift run rishi-e2e-host --cleanup-manifest=/absolute/path/to/recovery.json
      swift run rishi-e2e-host --help

    --cleanup-manifest=PATH
                 Recover every exactly owned resource recorded by an incomplete
                 run, then remove its recovery artifact after verified cleanup.
    --preflight  Validate live-run configuration and production dependencies.
    --help       Print this help without reading configuration or starting work.
    """
}

private enum CLIError: Error, LocalizedError {
    case missing(String)
    case invalidURL(String)
    case invalidPath(String)
    case invalidProductionEndpoint
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .missing(let key):
            return "Missing required E2E setting: \(key)"
        case .invalidURL(let key):
            return "Invalid URL in E2E setting: \(key)"
        case .invalidPath(let key):
            return "E2E path must be absolute and canonical: \(key)"
        case .invalidProductionEndpoint:
            return "RISHI_E2E_API_BASE_URL must be the canonical https://api.fidexa.org endpoint."
        case .invalidArguments:
            return "Invalid arguments. Use --help for supported routes."
        }
    }
}

import Foundation

public enum SharedReadingCLI {
    enum Route: Equatable {
        case help
        case preflight
        case recovery(URL)
        case execute
    }

    struct RecoveryConfiguration: Equatable, Sendable {
        let baseURL: URL
        let testAuthSecret: String
        let testDomain: String
        let temporaryRoot: URL
        let buildLockURL: URL
    }

    struct Actions: Sendable {
        let preflight: @Sendable ([String: String]) async throws -> Void
        let execute: @Sendable ([String: String]) async throws -> SharedReadingLiveRunEvidence
        let recover: @Sendable (URL, RecoveryConfiguration) async throws -> Void

        static let production = Actions(
            preflight: { environment in
                try await SharedReadingLiveRun.preflight(environment: environment)
            },
            execute: { environment in
                try await SharedReadingLiveRun.execute(environment: environment)
            },
            recover: { artifactURL, configuration in
                let accountClient = TestAccountClient(configuration: .init(
                    baseURL: configuration.baseURL,
                    testAuthSecret: configuration.testAuthSecret,
                    testDomain: configuration.testDomain
                ))
                try await SharedReadingRecoveryJournal.recover(
                    at: artifactURL,
                    temporaryRoot: configuration.temporaryRoot,
                    configuredBuildLockURL: configuration.buildLockURL,
                    accountClient: accountClient
                )
            }
        )
    }

    public static func run(
        arguments: [String],
        environment: [String: String]
    ) async throws -> [String] {
        try await run(arguments: arguments, environment: environment, actions: .production)
    }

    static func run(
        arguments: [String],
        environment: [String: String],
        actions: Actions
    ) async throws -> [String] {
        switch try parse(arguments: arguments) {
        case .help:
            return [usage]
        case .preflight:
            try await actions.preflight(environment)
            return ["Shared-reading E2E preflight passed."]
        case .recovery(let artifactURL):
            let configuration = try recoveryConfiguration(environment: environment)
            try await actions.recover(artifactURL, configuration)
            return ["Shared-reading E2E recovery completed."]
        case .execute:
            let evidence = try await actions.execute(environment)
            return [
                "Shared-reading E2E completed: \(evidence.runID)",
                "Participant observed sequence: \(evidence.participantProgressSequence)",
                "Temporary accounts deleted and verified: \(evidence.deletedAccountCount)",
            ]
        }
    }

    static func parse(arguments: [String]) throws -> Route {
        if arguments.isEmpty { return .execute }
        if arguments == ["--help"] || arguments == ["-h"] { return .help }
        if arguments == ["--preflight"] { return .preflight }
        if arguments.count == 1,
           let argument = arguments.first,
           argument.hasPrefix("--cleanup-manifest=") {
            let path = String(argument.dropFirst("--cleanup-manifest=".count))
            guard !path.isEmpty,
                  path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                throw Error.invalidPath("--cleanup-manifest")
            }
            return .recovery(URL(fileURLWithPath: path))
        }
        throw Error.invalidArguments
    }

    private static func recoveryConfiguration(
        environment: [String: String]
    ) throws -> RecoveryConfiguration {
        guard environment["RISHI_E2E_ALLOW_NETWORK"] == "1" else {
            throw Error.missing("RISHI_E2E_ALLOW_NETWORK=1")
        }
        let baseURL = try requiredURL(environment, key: "RISHI_E2E_API_BASE_URL")
        guard baseURL.absoluteString == "https://api-e2e.fidexa.org",
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.port == nil,
              baseURL.user == nil,
              baseURL.password == nil else {
            throw Error.invalidProductionEndpoint
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
            throw Error.invalidPath("RISHI_APPLE_XCODE_BUILD_LOCK_PATH")
        }

        return RecoveryConfiguration(
            baseURL: baseURL,
            testAuthSecret: try required(environment, key: "RISHI_E2E_TEST_AUTH_SECRET"),
            testDomain: try required(environment, key: "RISHI_E2E_TEST_DOMAIN"),
            temporaryRoot: temporaryRoot,
            buildLockURL: buildLockURL
        )
    }

    private static func required(_ environment: [String: String], key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw Error.missing(key)
        }
        return value
    }

    private static func requiredURL(_ environment: [String: String], key: String) throws -> URL {
        let value = try required(environment, key: key)
        guard let url = URL(string: value), url.absoluteString == value else {
            throw Error.invalidURL(key)
        }
        return url
    }

    private static func canonicalDirectoryURL(_ path: String, key: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw Error.invalidPath(key)
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
            throw Error.invalidPath(key)
        }
        return URL(fileURLWithPath: suppliedPath, isDirectory: true)
    }

    static let usage = """
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

    enum Error: Swift.Error, LocalizedError, Equatable {
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
                return "RISHI_E2E_API_BASE_URL must be the exact isolated https://api-e2e.fidexa.org endpoint."
            case .invalidArguments:
                return "Invalid arguments. Use --help for supported routes."
            }
        }
    }
}

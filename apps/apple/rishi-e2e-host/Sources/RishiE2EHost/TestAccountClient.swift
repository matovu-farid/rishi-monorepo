import Foundation

public enum TestAccountRole: String, Codable, Sendable, Equatable {
    case owner
    case participant
}

public struct TestAccount: Codable, Sendable, Equatable, CustomRedactable, CustomStringConvertible {
    public let role: TestAccountRole
    public let email: String
    public let password: String
    public let userID: String
    public let bearerToken: String

    public init(role: TestAccountRole, email: String, password: String, userID: String, bearerToken: String) {
        self.role = role
        self.email = email
        self.password = password
        self.userID = userID
        self.bearerToken = bearerToken
    }

    public var redactedDescription: String {
        "TestAccount(role: \(role.rawValue), email: \(email), userID: \(userID))"
    }

    public var description: String { redactedDescription }

    /// The only account data a peer UI test needs. Keep the bearer token and
    /// server user ID in the host process so they cannot leak through the
    /// on-disk launch manifest.
    public var credentials: TestAccountCredentials {
        TestAccountCredentials(role: role, email: email, password: password)
    }
}

public struct TestAccountCredentials: Codable, Sendable, Equatable {
    public let role: TestAccountRole
    public let email: String
    public let password: String

    public init(role: TestAccountRole, email: String, password: String) {
        self.role = role
        self.email = email
        self.password = password
    }
}

public struct TestAccountHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data = Data()) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol TestAccountTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse
}

public struct URLSessionTestAccountTransport: TestAccountTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // A production-network stall must become a bounded provisioning
        // failure so the host can run its exact-email compensation cleanup;
        // URLSession.shared otherwise permits an effectively unbounded wait.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TestAccountClientError.invalidResponse
        }
        return TestAccountHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

public enum TestAccountClientError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidResponse
    case httpFailure(statusCode: Int)
    case provisioningUnavailable
    case malformedSignInResponse
    case provisioningCleanupFailed
    case bookUploadTimedOut
    case deletionCleanupFailed
    case deletionVerificationFoundResidue

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .invalidResponse: return "The account service returned an invalid response."
        case .httpFailure(let statusCode): return "The account service returned HTTP \(statusCode)."
        case .provisioningUnavailable: return "The gated E2E account-provisioning route is unavailable."
        case .malformedSignInResponse: return "The account service returned an incomplete sign-in response."
        case .provisioningCleanupFailed: return "Provisioning failed and the temporary account could not be cleaned up."
        case .bookUploadTimedOut: return "The uploaded book did not become server-ready before the timeout."
        case .deletionCleanupFailed: return "Authenticated deletion failed and the gated test-account cleanup could not be confirmed."
        case .deletionVerificationFoundResidue: return "Account deletion verification found remaining account data."
        }
    }
}

public struct TestAccountClient: TestAccountManaging, Sendable {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let testAuthSecret: String
        public let testDomain: String
        public let signInPath: String
        public let deletionPath: String
        public let provisioningCleanupPath: String
        public let verificationPath: String
        public let bookReadinessPath: String
        public let dataUseConsent: String
        public let emailPrefix: String

        public init(
            baseURL: URL,
            testAuthSecret: String,
            testDomain: String,
            signInPath: String = "/test/sign-in",
            deletionPath: String = "/api/user",
            provisioningCleanupPath: String = "/test/users",
            verificationPath: String = "/api/user",
            bookReadinessPath: String = "/api/sync/changes?scope=full",
            dataUseConsent: String = "2026-07-29",
            emailPrefix: String = "rishi-e2e"
        ) {
            self.baseURL = baseURL
            self.testAuthSecret = testAuthSecret
            self.testDomain = testDomain
            self.signInPath = signInPath
            self.deletionPath = deletionPath
            self.provisioningCleanupPath = provisioningCleanupPath
            self.verificationPath = verificationPath
            self.bookReadinessPath = bookReadinessPath
            self.dataUseConsent = dataUseConsent
            self.emailPrefix = emailPrefix
        }
    }

    private let configuration: Configuration
    private let transport: any TestAccountTransport
    private let valueGenerator: @Sendable () -> String

    public init(
        configuration: Configuration,
        transport: any TestAccountTransport = URLSessionTestAccountTransport(),
        valueGenerator: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.valueGenerator = valueGenerator
    }

    /// Probe the gate without creating an account. The route validates the
    /// gate before request-body validation, so an enabled route returns 400
    /// for this deliberately incomplete body when the credit ledger is
    /// available. A disabled route returns 404; a missing ledger returns 503.
    /// This runs before any Xcode/simulator work.
    public func preflight() async throws {
        var request = try makeRequest(path: configuration.signInPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.testAuthSecret, forHTTPHeaderField: "X-Test-Auth-Secret")
        request.httpBody = Data("{}".utf8)
        let response = try await transport.send(request)
        guard response.statusCode == 400 else {
            if response.statusCode == 404 || response.statusCode == 503 {
                throw TestAccountClientError.provisioningUnavailable
            }
            throw TestAccountClientError.httpFailure(statusCode: response.statusCode)
        }
    }

    public func create() async throws -> TestAccount {
        try await create(role: .owner)
    }

    public func create(role: TestAccountRole) async throws -> TestAccount {
        let localPart = [configuration.emailPrefix, valueGenerator()]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        guard !localPart.isEmpty, !configuration.testDomain.isEmpty else {
            throw TestAccountClientError.invalidConfiguration("A test email domain is required.")
        }
        let email = "\(localPart)@\(configuration.testDomain)"
        let password = "Rishi-E2E-\(valueGenerator())-Aa1!"
        let body: [String: String] = ["email": email, "password": password]
        var request = try makeRequest(path: configuration.signInPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.testAuthSecret, forHTTPHeaderField: "X-Test-Auth-Secret")
        request.httpBody = try JSONEncoder().encode(body)

        let response: TestAccountHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            // A transport failure may mean the Worker created the account but
            // the response was lost. Compensate by the unique generated email.
            try await cleanupAfterProvisioningFailure(email: email, original: error)
        }

        guard (200..<300).contains(response.statusCode) else {
            // A 5xx can mean the Worker created the account and then failed
            // while signing in or granting credits. The address was freshly
            // generated by this client, and the gated route rejects existing
            // addresses, so compensate only for server failures. Keep 4xx
            // responses non-destructive: a collision or rejected request is
            // not evidence that this client owns the account.
            if response.statusCode >= 500 {
                try await cleanupAfterProvisioningFailure(
                    email: email,
                    original: TestAccountClientError.httpFailure(statusCode: response.statusCode)
                )
            }
            throw TestAccountClientError.httpFailure(statusCode: response.statusCode)
        }

        do {
            let signedIn = try JSONDecoder().decode(SignInResponse.self, from: response.data)
            guard !signedIn.token.isEmpty, !signedIn.userID.isEmpty else {
                throw TestAccountClientError.malformedSignInResponse
            }

            return TestAccount(
                role: role,
                // Keep the generated address as the lifecycle identity. The
                // server echoes it today, but accepting a different response
                // value could make deletion target the wrong account.
                email: email,
                password: password,
                userID: signedIn.userID,
                bearerToken: signedIn.token
            )
        } catch {
            try await cleanupAfterProvisioningFailure(email: email, original: error)
        }
    }

    private func cleanupAfterProvisioningFailure(email: String, original: Error) async throws -> Never {
        do {
            try await deleteProvisionedAccount(byEmail: email)
        } catch {
            throw TestAccountClientError.provisioningCleanupFailed
        }
        throw original
    }

    private func deleteProvisionedAccount(byEmail email: String) async throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw TestAccountClientError.invalidConfiguration("Could not encode the temporary test email.")
        }
        var request = try makeRequest(
            path: "\(configuration.provisioningCleanupPath)/\(encodedEmail)",
            method: "DELETE"
        )
        request.setValue(configuration.testAuthSecret, forHTTPHeaderField: "X-Test-Auth-Secret")
        var lastStatusCode = 503
        for attempt in 0..<3 {
            let response = try await transport.send(request)
            lastStatusCode = response.statusCode
            if (200..<300).contains(response.statusCode) || response.statusCode == 404 { return }
            // The production cleanup route can briefly surface a Worker or
            // ledger 5xx while the preceding account operation settles. A
            // bounded retry keeps teardown reliable without retrying a
            // deterministic client/configuration failure.
            if (response.statusCode == 502 || response.statusCode == 503 || response.statusCode == 504), attempt < 2 {
                try await Task.sleep(for: .seconds(5))
                continue
            }
            throw TestAccountClientError.httpFailure(statusCode: response.statusCode)
        }
        throw TestAccountClientError.httpFailure(statusCode: lastStatusCode)
    }

    /// Delete one account from an incomplete host manifest. The email must
    /// match this client's generated test-account namespace so a recovery
    /// command cannot be pointed at an unrelated user by accident.
    public func deleteProvisionedAccount(email: String) async throws {
        let normalized = email.lowercased()
        let prefix = "\(configuration.emailPrefix.lowercased())-"
        let suffix = "@\(configuration.testDomain.lowercased())"
        guard normalized.hasPrefix(prefix), normalized.hasSuffix(suffix) else {
            throw TestAccountClientError.invalidConfiguration("The recovery email is outside the configured test-account namespace.")
        }
        try await deleteProvisionedAccount(byEmail: normalized)
    }

    public func delete(_ account: TestAccount) async throws {
        var request = try makeRequest(path: configuration.deletionPath, method: "DELETE")
        request.setValue("Bearer \(account.bearerToken)", forHTTPHeaderField: "Authorization")
        let response: TestAccountHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            try await recoverDeletion(byEmail: account.email)
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            try await recoverDeletion(byEmail: account.email)
            return
        }
        guard Self.deletionWasConfirmed(response.data) else {
            // A successful HTTP status with an unexpected body is not enough
            // to claim teardown. Give the uniquely generated test address one
            // final gated cleanup attempt before failing closed.
            try await recoverDeletion(byEmail: account.email)
            return
        }
    }

    private func recoverDeletion(byEmail email: String) async throws {
        do {
            // This route delegates to the same canonical account-deletion
            // workflow, but does not depend on the bearer session surviving
            // the first failed request. The address is generated exclusively
            // by this client, so it cannot target an unrelated account.
            try await deleteProvisionedAccount(byEmail: email)
        } catch {
            throw TestAccountClientError.deletionCleanupFailed
        }
    }

    public func waitForBookUpload(_ account: TestAccount, expectedSHA256: String, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var request = try makeRequest(path: configuration.bookReadinessPath, method: "GET")
        request.setValue("Bearer \(account.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.dataUseConsent, forHTTPHeaderField: "X-Rishi-Data-Use-Consent")
        while clock.now < deadline {
            do {
                let response = try await transport.send(request)
                guard (200..<300).contains(response.statusCode) else {
                    // Readiness is a polling operation. Retry transient Worker
                    // failures, but fail immediately on a deterministic client
                    // or authorization error.
                    if (500..<600).contains(response.statusCode) {
                        try await Task.sleep(for: .seconds(1))
                        continue
                    }
                    throw TestAccountClientError.httpFailure(statusCode: response.statusCode)
                }
                if Self.containsUploadedBook(response.data, expectedSHA256: expectedSHA256) { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TestAccountClientError {
                throw error
            } catch {
                // A timeout or connection reset can occur while the app is
                // still uploading. Keep polling until the caller's bounded
                // deadline instead of abandoning an otherwise valid run.
            }
            if clock.now < deadline { try await Task.sleep(for: .seconds(1)) }
        }
        throw TestAccountClientError.bookUploadTimedOut
    }

    public func verifyDeleted(_ account: TestAccount) async throws {
        var request = try makeRequest(path: configuration.verificationPath, method: "GET")
        request.setValue("Bearer \(account.bearerToken)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        // The canonical deletion endpoint removes the Better Auth session as
        // part of the same transaction. A subsequent authenticated profile
        // request therefore returns either 404 (no user) or 401 (no session).
        // Both are a clean result; a 2xx response must still be inspected for
        // explicit residue markers.
        if response.statusCode == 401 || response.statusCode == 404 || response.statusCode == 410 { return }
        guard (200..<300).contains(response.statusCode) else {
            throw TestAccountClientError.httpFailure(statusCode: response.statusCode)
        }
        guard deletionResponseIsEmpty(response.data) else {
            throw TestAccountClientError.deletionVerificationFoundResidue
        }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw TestAccountClientError.invalidConfiguration("Invalid account service path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        return request
    }

    private func deletionResponseIsEmpty(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }
        if dictionary["userExists"] as? Bool == true || dictionary["user"] is [String: Any] || dictionary["user"] as? Bool == true {
            return false
        }
        if numericResidue(in: dictionary["books"]) > 0 || numericResidue(in: dictionary["sessions"]) > 0 || numericResidue(in: dictionary["ledger"]) > 0 {
            return false
        }
        if dictionary["ledger"] as? Bool == true { return false }
        if dictionary["deleted"] as? Bool == true || dictionary["alreadyDeleted"] as? Bool == true {
            return true
        }
        if dictionary["userExists"] as? Bool == false { return true }
        return false
    }

    private static func deletionWasConfirmed(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["ok"] as? Bool == true
    }

    private func numericResidue(in value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let array = value as? [Any] { return array.isEmpty ? 0 : 1 }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty ? 0 : 1 }
        return 0
    }

    private static func containsUploadedBook(_ data: Data, expectedSHA256: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changes = object["changes"] as? [[String: Any]] else { return false }
        return changes.contains { change in
            guard (change["kind"] as? String) == "book",
                  (change["deleted"] as? Bool) != true,
                  let payload = change["payload"] as? [String: Any],
                  let fileHash = payload["file_hash"] as? String,
                  fileHash.caseInsensitiveCompare(expectedSHA256) == .orderedSame,
                  let fileKey = payload["file_r2_key"] as? String,
                  !fileKey.isEmpty else { return false }
            if let fileSize = payload["file_size"] as? NSNumber { return fileSize.int64Value > 0 }
            return false
        }
    }

    private struct SignInResponse: Decodable {
        let token: String
        let userID: String
        let email: String?

        private enum CodingKeys: String, CodingKey {
            case token
            case userID = "userId"
            case email
        }
    }
}

public protocol CustomRedactable {
    var redactedDescription: String { get }
}

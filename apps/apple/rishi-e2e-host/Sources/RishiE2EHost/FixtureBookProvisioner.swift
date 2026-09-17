import Foundation

public struct FixtureBookHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data = Data()) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol FixtureBookTransport: Sendable {
    func send(_ request: URLRequest) async throws -> FixtureBookHTTPResponse
}

public struct URLSessionFixtureBookTransport: FixtureBookTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> FixtureBookHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FixtureBookProvisionerError.invalidResponse
        }
        return FixtureBookHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

public struct ProvisionedFixtureBook: Sendable, Equatable {
    public let bookID: UUID
    public let r2Key: String
    public let manifest: RealBookFixture.Manifest
}

public enum FixtureBookProvisionerError: Error, LocalizedError, Equatable {
    case invalidConfiguration
    case unreadableFixture
    case httpFailure(phase: String, statusCode: Int)
    case malformedUploadURLResponse
    case pushRejected
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The fixture-book provisioner is not configured with a valid API URL."
        case .unreadableFixture: return "The fixture book could not be read."
        case .httpFailure(let phase, let statusCode): return "Fixture-book \(phase) returned HTTP \(statusCode)."
        case .malformedUploadURLResponse: return "The fixture-book upload URL response was invalid."
        case .pushRejected: return "The server rejected the fixture-book metadata."
        case .invalidResponse: return "The fixture-book service returned an invalid response."
        }
    }
}

/// Provisions a test fixture through the exact upload-url → R2 PUT → sync-push
/// protocol used by the Apple app. It deliberately has no test-only book route.
public struct FixtureBookProvisioner: Sendable {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let uploadURLPath: String
        public let pushPath: String
        public let dataUseConsent: String

        public init(
            baseURL: URL,
            uploadURLPath: String = "/api/sync/upload-url",
            pushPath: String = "/api/sync/push",
            dataUseConsent: String = "2026-07-29"
        ) {
            self.baseURL = baseURL
            self.uploadURLPath = uploadURLPath
            self.pushPath = pushPath
            self.dataUseConsent = dataUseConsent
        }
    }

    private let configuration: Configuration
    private let transport: any FixtureBookTransport
    private let identifierGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        configuration: Configuration,
        transport: any FixtureBookTransport = URLSessionFixtureBookTransport(),
        identifierGenerator: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.identifierGenerator = identifierGenerator
        self.now = now
    }

    public func provision(_ fixture: RealBookFixture, for account: TestAccount) async throws -> ProvisionedFixtureBook {
        guard configuration.baseURL.scheme != nil, configuration.baseURL.host != nil else {
            throw FixtureBookProvisionerError.invalidConfiguration
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: fixture.sourceURL)
        } catch {
            throw FixtureBookProvisionerError.unreadableFixture
        }
        let bookID = identifierGenerator()
        let operationID = identifierGenerator()
        let r2Key = "books/\(account.userID)/\(bookID.uuidString.lowercased()).\(fixture.manifest.format.rawValue)"
        let contentType = contentType(for: fixture.manifest.format)

        var uploadURLRequest = try request(path: configuration.uploadURLPath, method: "POST", account: account)
        uploadURLRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadURLRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": r2Key,
            "content_type": contentType
        ])
        let signedURLResponse = try await transport.send(uploadURLRequest)
        try requireSuccess(signedURLResponse, phase: "upload URL")
        let signedURL = try decodeUploadURL(from: signedURLResponse.data)

        var putRequest = URLRequest(url: signedURL)
        putRequest.httpMethod = "PUT"
        putRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = bytes
        let putResponse = try await transport.send(putRequest)
        try requireSuccess(putResponse, phase: "file upload")

        var pushRequest = try request(path: configuration.pushPath, method: "POST", account: account)
        pushRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pushRequest.httpBody = try JSONSerialization.data(withJSONObject: ["changes": [[
            "kind": "book",
            "id": bookID.uuidString.lowercased(),
            "operation_id": operationID.uuidString.lowercased(),
            "payload": [
                "id": bookID.uuidString.lowercased(),
                "title": fixture.sourceURL.deletingPathExtension().lastPathComponent,
                "format_type": fixture.manifest.format.rawValue,
                "file_r2_key": r2Key,
                "file_hash": fixture.manifest.sha256,
                "file_size": bytes.count
            ],
            "updated_at": now().timeIntervalSinceReferenceDate,
            "deleted": false
        ]]])
        let pushResponse = try await transport.send(pushRequest)
        try requireSuccess(pushResponse, phase: "metadata push")
        if let accepted = try? JSONSerialization.jsonObject(with: pushResponse.data) as? [String: Any],
           accepted["accepted"] as? Bool == false {
            throw FixtureBookProvisionerError.pushRejected
        }

        return ProvisionedFixtureBook(bookID: bookID, r2Key: r2Key, manifest: fixture.manifest)
    }

    private func request(path: String, method: String, account: TestAccount) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw FixtureBookProvisionerError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(account.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.dataUseConsent, forHTTPHeaderField: "X-Rishi-Data-Use-Consent")
        return request
    }

    private func requireSuccess(_ response: FixtureBookHTTPResponse, phase: String) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw FixtureBookProvisionerError.httpFailure(phase: phase, statusCode: response.statusCode)
        }
    }

    private func decodeUploadURL(from data: Data) throws -> URL {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["url"] as? String,
              let url = URL(string: string),
              url.scheme == "https" else {
            throw FixtureBookProvisionerError.malformedUploadURLResponse
        }
        return url
    }

    private func contentType(for format: RealBookFormat) -> String {
        switch format {
        case .epub: return "application/epub+zip"
        case .pdf: return "application/pdf"
        }
    }
}

public protocol FixtureBookProvisioning: Sendable {
    func provision(_ fixture: RealBookFixture, for account: TestAccount) async throws -> ProvisionedFixtureBook
}

extension FixtureBookProvisioner: FixtureBookProvisioning {}

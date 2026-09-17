import Foundation
import XCTest
@testable import RishiE2EHost

final class FixtureBookProvisionerTests: XCTestCase {
    func testProvisionUploadsFixtureThenPushesServerReadyBookMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("shared-reading.epub")
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x65, 0x70, 0x75, 0x62])
        try bytes.write(to: source)
        let fixture = try RealBookFixtures.resolve(role: .owner, path: source)
        let ids = IdentifierSequence([
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ])
        let transport = RecordingTransport(responses: [
            .json(["url": "https://storage.example.test/signed-put"]),
            .status(200),
            .json(["accepted": true, "outcomes": []])
        ])
        let provisioner = FixtureBookProvisioner(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!),
            transport: transport,
            identifierGenerator: { ids.next() },
            now: { Date(timeIntervalSinceReferenceDate: 1234) }
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "server-owner", bearerToken: "token-1")

        let provisioned = try await provisioner.provision(fixture, for: account)

        XCTAssertEqual(provisioned.bookID.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(provisioned.r2Key, "books/server-owner/00000000-0000-0000-0000-000000000001.epub")
        XCTAssertEqual(transport.requests.count, 3)

        let uploadURL = transport.requests[0]
        XCTAssertEqual(uploadURL.url?.path, "/api/sync/upload-url")
        XCTAssertEqual(uploadURL.httpMethod, "POST")
        XCTAssertEqual(uploadURL.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(uploadURL.value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent"), "2026-07-29")
        XCTAssertEqual(try json(uploadURL.httpBody)["key"] as? String, provisioned.r2Key)
        XCTAssertEqual(try json(uploadURL.httpBody)["content_type"] as? String, "application/epub+zip")

        let put = transport.requests[1]
        XCTAssertEqual(put.url?.absoluteString, "https://storage.example.test/signed-put")
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/epub+zip")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(put.httpBody, bytes)

        let push = transport.requests[2]
        XCTAssertEqual(push.url?.path, "/api/sync/push")
        XCTAssertEqual(push.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let change = try XCTUnwrap((try json(push.httpBody)["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["kind"] as? String, "book")
        XCTAssertEqual(change["id"] as? String, provisioned.bookID.uuidString)
        XCTAssertEqual(change["operation_id"] as? String, "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(change["updated_at"] as? Double, 1234)
        XCTAssertEqual(change["deleted"] as? Bool, false)
        let payload = try XCTUnwrap(change["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, provisioned.bookID.uuidString)
        XCTAssertEqual(payload["title"] as? String, "shared-reading")
        XCTAssertEqual(payload["format_type"] as? String, "epub")
        XCTAssertEqual(payload["file_r2_key"] as? String, provisioned.r2Key)
        XCTAssertEqual(payload["file_hash"] as? String, fixture.manifest.sha256)
        XCTAssertEqual(payload["file_size"] as? Int, bytes.count)
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private final class IdentifierSequence: @unchecked Sendable {
        private var values: [UUID]
        init(_ values: [UUID]) { self.values = values }
        func next() -> UUID { values.removeFirst() }
    }

    private final class RecordingTransport: FixtureBookTransport, @unchecked Sendable {
        struct Response {
            let statusCode: Int
            let data: Data

            static func json(_ object: [String: Any]) -> Self {
                .init(statusCode: 200, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            }

            static func status(_ code: Int) -> Self { .init(statusCode: code, data: Data()) }
        }
        private(set) var requests: [URLRequest] = []
        private var responses: [Response]
        init(responses: [Response]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> FixtureBookHTTPResponse {
            requests.append(request)
            let response = responses.removeFirst()
            return .init(statusCode: response.statusCode, data: response.data)
        }
    }
}

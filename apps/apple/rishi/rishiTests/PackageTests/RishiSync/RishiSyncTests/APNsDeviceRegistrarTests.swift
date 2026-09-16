@testable import rishi
import Testing
import Foundation



/// SYNC-06 — APNs device registration calls `DevicesRegisterEndpoint`
/// (POST /api/devices/register) once after sign-in. The registrar is
/// idempotent against the same token.
@Suite("APNsDeviceRegistrar — token hex + idempotent POST", .serialized)
struct APNsDeviceRegistrarTests {

    final class APNsMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
        nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
        override class var storage: MockURLProtocolStorage { _storage }
        static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
            get { _storage.handler } set { _storage.handler = newValue }
        }
        static func reset() { _storage.reset() }
        static func capturedSnapshot() -> [URLRequest] { _storage.captured }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APNsMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token")
        )
    }

    private func successBody() -> Data {
        Data("""
        { "device_id": "11111111-1111-1111-1111-111111111111", "registered_at": 700000000 }
        """.utf8)
    }

    // MARK: - Tests

    @Test("tokenHexString lowercases + zero-pads bytes")
    func tokenHexLowercaseZeroPadded() {
        let data = Data([0x00, 0xff, 0x10, 0xab])
        let hex = APNsDeviceRegistrar.tokenHexString(from: data)
        #expect(hex == "00ff10ab")
    }

    @Test("register POSTs /api/devices/register with snake_case body")
    func registerSendsExpectedPayload() async throws {
        APNsMockURLProtocol.reset()
        let session = makeSession()
        let client = makeWorkerClient(session: session)
        APNsMockURLProtocol.handler = { _ in (200, self.successBody(), nil) }

        let registrar = APNsDeviceRegistrar(workerClient: client)
        let tokenData = Data([0xde, 0xad, 0xbe, 0xef])
        try await registrar.register(token: tokenData, platform: "ios", appVersion: "1.0.0")

        let captured = APNsMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
        let request = try #require(captured.first)
        #expect(request.url?.path == "/api/devices/register")
        #expect(request.httpMethod == "POST")

        // Body is consumed via httpBodyStream on URLProtocol — capture it.
        let body = request.httpBody ?? Data(reading: request.httpBodyStream)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["device_token"] as? String == "deadbeef")
        #expect(json?["platform"] as? String == "ios")
        #expect(json?["app_version"] as? String == "1.0.0")
        #expect(json?["bundle_id"] as? String == "org.fidexa.rishi")
        #expect(json?["topic"] as? String == "org.fidexa.rishi")
    }

    @Test("register is idempotent against same token (second call no-ops)")
    func registerIsIdempotentForSameToken() async throws {
        APNsMockURLProtocol.reset()
        let session = makeSession()
        let client = makeWorkerClient(session: session)
        APNsMockURLProtocol.handler = { _ in (200, self.successBody(), nil) }

        let registrar = APNsDeviceRegistrar(workerClient: client)
        let token = Data([0x01, 0x02, 0x03])
        try await registrar.register(token: token, platform: "ios", appVersion: "1.0.0")
        try await registrar.register(token: token, platform: "ios", appVersion: "1.0.0")

        let captured = APNsMockURLProtocol.capturedSnapshot()
        #expect(captured.count == 1)
    }
}

// MARK: - InputStream helper

private extension Data {
    /// Read all bytes from `stream` (URLProtocol's httpBodyStream surface).
    init(reading stream: InputStream?) {
        guard let stream else { self = Data(); return }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        self = data
    }
}

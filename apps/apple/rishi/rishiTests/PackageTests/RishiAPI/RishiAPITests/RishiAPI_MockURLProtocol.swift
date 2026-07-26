@testable import rishi
import Foundation

/// Test fixture intercepting URLSession requests via the URLProtocol API.
/// Configure a session with `URLSessionConfiguration.ephemeral` setting
/// `protocolClasses = [MockURLProtocol.self]`; then push a handler before
/// the test issues its request.
///
/// `requestHandler` is invoked on a background queue per-request and returns
/// (HTTPURLResponse, body Data) OR throws to simulate a transport error.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// Per-request handler. Set/replace before each test.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Records every request the SUT issued, in order. Cleared per-test.
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requestHandler = nil
        recordedRequests = []
    }

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        requestHandler = handler
    }

    static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

import Foundation

/// Test-only URLProtocol that lets a suite script (status, body, headers)
/// per request and inspect captured requests.
///
/// Mirrors the StubURLProtocol pattern from RishiAPI/RishiAuth test targets
/// but lives local to RishiSync so the package keeps a zero cross-package
/// test dependency on RishiAPITests' internal helpers.
///
/// Use with a per-suite session:
/// ```swift
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
/// MockURLProtocol.handler = { request in (200, body, nil) }
/// ```
///
/// IMPORTANT: Tests that reach this protocol MUST be inside a
/// `@Suite(.serialized)` — `handler`/`captured` are nonisolated(unsafe)
/// static state that Swift Testing would otherwise race across @Test
/// methods.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// (status, body bytes, optional response headers). Set per-test on the
    /// main thread before exercising the SUT.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))?

    /// Captured requests for assertions. Cleared per test via `reset()`.
    nonisolated(unsafe) static var captured: [URLRequest] = []

    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, body, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers ?? ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Reset between tests. Call at the top of every @Test method.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        captured.removeAll()
    }

    /// Snapshot the captured requests under the lock.
    static func capturedSnapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
}

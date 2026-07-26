@testable import rishi
import Foundation

/// Test-only URLProtocol base class. Each @Suite that needs an isolated
/// MockURLProtocol declares its own subclass so the static `handler` +
/// `captured` storage doesn't race across parallel suites. The subclass
/// adds zero behavior — it only gives the type system a distinct identity
/// per suite, which means distinct static storage (Swift type metadata).
///
/// Use with a per-suite session:
/// ```swift
/// final class MyMockProto: MockURLProtocolBase {}
/// // in @Suite(.serialized):
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MyMockProto.self]
/// let session = URLSession(configuration: config)
/// MyMockProto.handler = { req in (200, body, nil) }
/// ```
///
/// IMPORTANT: Even with per-suite subclasses, the surrounding @Suite MUST
/// be `.serialized` because `handler`/`captured` are nonisolated(unsafe)
/// static state that Swift Testing would otherwise race across parallel
/// @Test methods within the suite.
class MockURLProtocolBase: URLProtocol, @unchecked Sendable {

    class var storage: MockURLProtocolStorage { fatalError("subclass must override storage") }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let store = Self.storage
        store.append(request)
        guard let handler = store.handler else {
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
}

/// Lock-guarded handler + captured-requests storage. One instance per
/// MockURLProtocolBase subclass; subclasses inject their own via the
/// `storage` class-property override.
final class MockURLProtocolStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))?
    private var _captured: [URLRequest] = []

    var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    var captured: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        _captured.append(request)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _captured.removeAll()
    }
}

// MARK: - Per-suite subclasses
//
// Each @Suite that scripts HTTP gets its own subclass + static storage so
// parallel suites cannot stomp on each other's captured requests / handler.
// `@Suite(.serialized)` still required to keep @Test methods within ONE
// suite from racing each other.

final class BookUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class PositionUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class HighlightUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class BookmarkUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class RemoteChangeFetcherMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class ConversationUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class MessageUploaderMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

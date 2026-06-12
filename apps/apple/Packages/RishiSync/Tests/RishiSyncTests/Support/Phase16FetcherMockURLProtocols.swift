import Foundation

/// Per-suite `MockURLProtocolBase` subclasses for Phase 16-05 inbound
/// fetchers. Distinct types per suite → distinct static storage → no
/// cross-suite races when Swift Testing parallelizes suites.

final class ConversationsFetcherMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

final class MessagesFetcherMockURLProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { _storage.handler } set { _storage.handler = newValue }
    }
    static func reset() { _storage.reset() }
    static func capturedSnapshot() -> [URLRequest] { _storage.captured }
}

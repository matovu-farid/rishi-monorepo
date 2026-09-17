import Foundation
import Testing

@testable import rishi

@Suite("Shared reading API", .serialized)
struct SharedReadingAPITests {
    @Test("refreshes once after an expired bearer token")
    func refreshesAfterUnauthorizedResponse() async throws {
        let tokenProvider = TestTokenProvider(value: "expired-token")
        let counter = LockedCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = URL(string: "https://api.rishi.test")!

        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.setHandler { request in
            if counter.increment() == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!,
                    Data()
                )
            }

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data(#"{"sessions":[]}"#.utf8)
            )
        }

        let api = SharedReadingAPI(
            baseURL: baseURL,
            session: session,
            tokenProvider: tokenProvider,
            refreshAuthentication: {
                await tokenProvider.set("fresh-token")
            }
        )

        let response = try await api.activeSessions()

        #expect(response.sessions.isEmpty)
        #expect(counter.value == 2)
        #expect(MockURLProtocol.recordedRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer expired-token")
        #expect(MockURLProtocol.recordedRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test("reports an untyped 404 as an unavailable service when the route is missing")
    func missingCreateRouteIsNotReportedAsInvalidLink() async {
        let tokenProvider = TestTokenProvider(value: "test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data(#"{"error":"Not Found"}"#.utf8)
            )
        }

        let api = SharedReadingAPI(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: tokenProvider,
            requestTimeout: 0.5
        )

        do {
            _ = try await api.create(bookId: UUID().uuidString, idempotencyKey: UUID().uuidString)
            Issue.record("expected create to fail")
        } catch let error as SharedReadingError {
            #expect(error.code == .serviceUnavailable)
            #expect(error.message == "The reading-session service is not available yet.")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("turns a request timeout into a visible retryable error")
    func requestTimeoutIsReported() async {
        let tokenProvider = TestTokenProvider(value: "test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.setHandler { _ in
            // Deliberately never call the URLProtocol client. URLSession must
            // terminate the request using the request timeout.
            Thread.sleep(forTimeInterval: 0.25)
            throw URLError(.timedOut)
        }

        let api = SharedReadingAPI(
            baseURL: URL(string: "https://api.rishi.test")!,
            session: session,
            tokenProvider: tokenProvider,
            requestTimeout: 0.01
        )

        do {
            _ = try await api.activeSessions()
            Issue.record("expected request to time out")
        } catch let error as SharedReadingError {
            #expect(error.code == .serviceUnavailable)
            #expect(error.message == "The reading-session service did not respond in time. Try again.")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

private actor TestTokenProvider: TokenProvider {
    private var value: String?

    init(value: String?) {
        self.value = value
    }

    func token() async -> String? {
        value
    }

    func set(_ value: String?) {
        self.value = value
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

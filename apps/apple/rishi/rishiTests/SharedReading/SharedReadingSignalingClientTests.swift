import Foundation
import Testing

@testable import rishi

@Suite("Shared reading signaling websocket origin", .serialized)
struct SharedReadingSignalingClientTests {
    @Test("creates a task only for matching secure websocket admissions")
    func createsTaskForMatchingOrigin() async throws {
        let recorder = RecordingWebSocketTaskFactory()
        let client = makeClient(recorder: recorder)

        try await client.connect(
            admission: admission(url: "wss://sharing-e2e.fidexa.org:443/v2/sessions/s_123/wss"),
            bearerToken: "bearer-token",
            refreshAdmission: nil,
            refreshBearerToken: nil
        )

        #expect(recorder.count == 1)
        await client.disconnect()
    }

    @Test("rejects invalid initial admissions without creating a websocket task")
    func rejectsInvalidInitialAdmissionsWithoutCreatingTask() async {
        let invalidURLs = [
            "wss://sharing.fidexa.org/v2/sessions/s_123/wss",
            "ws://sharing-e2e.fidexa.org/v2/sessions/s_123/wss",
            "wss://user@sharing-e2e.fidexa.org/v2/sessions/s_123/wss",
            "wss://sharing-e2e.fidexa.org/v2/sessions/s_123/wss?token=unexpected",
            "wss://sharing-e2e.fidexa.org/v2/sessions/s_123/wss#fragment",
            "wss://sharing-e2e.fidexa.org:8443/v2/sessions/s_123/wss",
        ]

        for url in invalidURLs {
            let recorder = RecordingWebSocketTaskFactory()
            let client = makeClient(recorder: recorder)
            do {
                try await client.connect(
                    admission: admission(url: url),
                    bearerToken: "bearer-token",
                    refreshAdmission: nil,
                    refreshBearerToken: nil
                )
                Issue.record("expected \(url) to be rejected")
            } catch let error as SharedReadingError {
                #expect(error.code == .serviceUnavailable)
                #expect(error.retryable)
            } catch {
                Issue.record("expected SharedReadingError for \(url), got \(error)")
            }
            #expect(recorder.count == 0)
        }
    }

    @Test("rejects refreshed admissions from another origin without creating another websocket task")
    func rejectsInvalidRefreshedAdmissionWithoutCreatingTask() async throws {
        let recorder = RecordingWebSocketTaskFactory()
        let client = makeClient(recorder: recorder, backoff: { _ in .zero })
        let events = client.events

        try await client.connect(
            admission: admission(url: "wss://sharing-e2e.fidexa.org/v2/sessions/s_123/wss"),
            bearerToken: "bearer-token",
            refreshAdmission: {
                self.admission(url: "wss://sharing.fidexa.org/v2/sessions/s_123/wss")
            },
            refreshBearerToken: nil
        )
        await client.handleDisconnect(generation: 1)

        let failure = await firstServiceFailure(from: events)
        #expect(failure?.code == .serviceUnavailable)
        #expect(failure?.retryable == true)
        #expect(recorder.count == 1)
        await client.disconnect()
    }

    private func makeClient(
        recorder: RecordingWebSocketTaskFactory,
        backoff: @escaping @Sendable (Int) -> Duration = { _ in .seconds(60) }
    ) -> SharedReadingSignalingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return SharedReadingSignalingClient(
            expectedSharingWebSocketOrigin: URL(string: "wss://sharing-e2e.fidexa.org")!,
            urlSession: session,
            backoff: backoff,
            webSocketTaskFactory: { url, protocols in
                recorder.makeTask(url: url, protocols: protocols, using: session)
            }
        )
    }

    private func admission(url: String) -> SharedReadingAdmission {
        SharedReadingAdmission(
            admissionTicket: "admission-ticket",
            websocketURL: URL(string: url)!,
            roomEpoch: 1,
            connectionGeneration: 1,
            status: .waiting
        )
    }

    private func firstServiceFailure(
        from events: AsyncStream<SharedReadingSignalingEvent>
    ) async -> SharedReadingError? {
        await withTaskGroup(of: SharedReadingError?.self) { group in
            group.addTask {
                for await event in events {
                    if case .error(let error) = event { return error }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private final class RecordingWebSocketTaskFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var taskCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return taskCount
    }

    func makeTask(url: URL, protocols: [String], using session: URLSession) -> URLSessionWebSocketTask {
        lock.lock()
        taskCount += 1
        lock.unlock()
        return session.webSocketTask(with: url, protocols: protocols)
    }
}

private final class NoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

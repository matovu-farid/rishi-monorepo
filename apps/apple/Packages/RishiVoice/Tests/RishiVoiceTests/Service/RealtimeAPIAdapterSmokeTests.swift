import Testing
import Foundation
@testable import RishiVoice

/// Smoke tests for `RealtimeAPIAdapter` (production impl) and
/// `FakeRealtimeClient` (test impl) — both conform to `RealtimeClientAPI`.
///
/// The adapter smoke tests do NOT exercise a real WebRTC negotiation; that
/// requires a live OpenAI ephemeral key + microphone. We assert only that
/// the adapter can be constructed, starts in `.disconnected`, and that
/// `disconnect()` is idempotent. End-to-end coverage lives in the harness
/// (Spike B) and the future device-bound CI lane (VOICE-04+).
@Suite("RealtimeAPIAdapter smoke")
struct RealtimeAPIAdapterSmokeTests {

    @Test("Adapter starts in .disconnected status")
    func adapterStartsDisconnected() async {
        let adapter = RealtimeAPIAdapter()
        let status = await adapter.currentStatus()
        #expect(status == .disconnected)
    }

    @Test("Adapter disconnect() is idempotent on a never-connected client")
    func disconnectIsIdempotent() async {
        let adapter = RealtimeAPIAdapter()
        await adapter.disconnect()
        await adapter.disconnect()
        let status = await adapter.currentStatus()
        #expect(status == .disconnected)
    }

    @Test("FakeRealtimeClient records connect call + transitions to connected")
    func fakeRecordsConnect() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "stub-key-1")
        #expect(fake.connectCalls == ["stub-key-1"])
        let status = await fake.currentStatus()
        #expect(status == .connected)
    }

    @Test("FakeRealtimeClient inject(transcript:) reaches the stream")
    func fakeInjectsTranscript() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let stream = fake.transcriptStream()
        var iter = stream.makeAsyncIterator()

        fake.inject(transcript: RealtimeTranscriptEvent(
            role: .assistant,
            content: "hello",
            isFinal: true
        ))
        let event = await iter.next()
        #expect(event?.content == "hello")
        #expect(event?.role == .assistant)
        #expect(event?.isFinal == true)
    }

    @Test("FakeRealtimeClient inject(error:) reaches the stream")
    func fakeInjectsError() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let stream = fake.errorStream()
        var iter = stream.makeAsyncIterator()

        fake.inject(error: RealtimeClientError(code: "server_error", message: "boom"))
        let received = await iter.next()
        #expect(received?.code == "server_error")
        #expect(received?.message == "boom")
    }

    @Test("FakeRealtimeClient failNextConnect throws then clears")
    func failNextConnectThrowsThenClears() async throws {
        struct StubFailure: Error, Equatable {}
        let fake = FakeRealtimeClient()
        fake.failNextConnect(with: StubFailure())

        await #expect(throws: StubFailure.self) {
            try await fake.connect(ephemeralKey: "k1")
        }
        // Second call succeeds because the failure was one-shot.
        try await fake.connect(ephemeralKey: "k2")
        // Failed-call key is still recorded (the lock-protected block runs
        // before the throw); both keys appear in connectCalls.
        #expect(fake.connectCalls == ["k1", "k2"])
    }

    @Test("FakeRealtimeClient disconnect() finishes streams and increments count")
    func disconnectFinishesStreams() async throws {
        let fake = FakeRealtimeClient()
        try await fake.connect(ephemeralKey: "k")

        let stream = fake.transcriptStream()
        await fake.disconnect()
        #expect(fake.disconnectCalls == 1)

        // After disconnect, the stream should finish — iterator yields nil.
        var iter = stream.makeAsyncIterator()
        let next = await iter.next()
        #expect(next == nil)

        let status = await fake.currentStatus()
        #expect(status == .disconnected)
    }
}

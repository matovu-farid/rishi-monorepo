import Foundation
import Testing
import RishiVoice
@testable import rishi

@MainActor
@Suite("Voice session registry", .serialized)
struct VoiceSessionRegistryTests {

    private final class FakeSession: VoiceSessionRegistrySession, @unchecked Sendable {
        var id: String?
        private(set) var parkCount = 0
        private(set) var resumeCount = 0
        private(set) var endCount = 0

        init(id: String? = "rishi-test") { self.id = id }

        var rishiSessionId: String? { get async { id } }

        func parkForBackground() async { parkCount += 1 }
        func resumeFromBackground() async { resumeCount += 1 }
        func end() async -> String? {
            endCount += 1
            return id
        }
    }

    private actor EndRecorder {
        private(set) var ids: [String] = []
        private(set) var shouldFail = false

        func record(_ id: String) throws {
            ids.append(id)
            if shouldFail { throw CancellationError() }
        }

        func setShouldFail(_ value: Bool) { shouldFail = value }
    }

    @Test("registration and park/resume retain one session and reset expiry")
    func registrationParkResume() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let session = FakeSession()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .milliseconds(80),
            endServerSession: { _ in }
        )

        await registry.register(session)
        #expect(registry.state == .live)
        #expect(registry.persistedServerSessionID == "rishi-test")

        await registry.park()
        #expect(registry.state == .parked)
        #expect(session.parkCount == 1)
        try await Task.sleep(for: .milliseconds(30))
        await registry.resume()
        #expect(registry.state == .live)
        #expect(session.resumeCount == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.endCount == 0)
    }

    @Test("expiry closes locally once and clears persistence after server confirmation")
    func expiryClosesOnce() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let session = FakeSession(id: "expiry-id")
        let recorder = EndRecorder()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .milliseconds(20),
            endServerSession: { id in try await recorder.record(id) }
        )

        await registry.register(session)
        await registry.park()
        try await Task.sleep(for: .milliseconds(80))
        await registry.waitForServerEnd()
        #expect(session.endCount == 1)
        #expect(await recorder.ids.count == 1)
        #expect(registry.state == .ended)
        #expect(registry.persistedServerSessionID == nil)
    }

    @Test("explicit close bypasses the park grace period")
    func backgroundClose() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let session = FakeSession(id: "background-id")
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .seconds(60),
            endServerSession: { _ in }
        )

        await registry.register(session)
        await registry.park()
        await registry.close()
        #expect(session.endCount == 1)
        await registry.waitForServerEnd()
        #expect(registry.state == .ended)
    }

    @Test("close is idempotent and recovery preserves IDs on failed delivery")
    func closeAndRecovery() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let recorder = EndRecorder()
        await recorder.setShouldFail(true)
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            endServerSession: { id in
                try await recorder.record(id)
            }
        )
        registry.persistedServerSessionID = "orphan-id"
        await registry.recoverPersistedSession()
        #expect(await recorder.ids == ["orphan-id"])
        #expect(registry.persistedServerSessionID == "orphan-id")
        await recorder.setShouldFail(false)
        await registry.recoverPersistedSession()
        #expect(registry.persistedServerSessionID == nil)
    }
}

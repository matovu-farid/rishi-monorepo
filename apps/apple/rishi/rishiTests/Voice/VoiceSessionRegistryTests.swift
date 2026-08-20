import Foundation
import Testing

@testable import rishi

@MainActor
@Suite("Voice session registry", .serialized)
struct VoiceSessionRegistryTests {

    @Test("cleanup queue drains each registered reader exactly once")
    func cleanupQueueDrainsRegisteredReadersOnce() {
        let queue = VoiceSessionCleanupQueue()
        let first = ReaderSessionIdentity()
        let second = ReaderSessionIdentity()

        queue.register(first)
        queue.register(first)
        queue.register(second)

        #expect(queue.count == 2)
        #expect(Set(queue.takeAll()) == Set([first, second]))
        #expect(queue.count == 0)
        #expect(queue.takeAll().isEmpty)
    }

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

    private actor EndGate {
        private(set) var started = false
        private var released = false

        func markStarted() { started = true }
        func release() { released = true }

        func waitForRelease() async {
            while !released {
                await Task.yield()
            }
        }
    }

    private actor CompletionFlag {
        private(set) var value = false

        func markComplete() { value = true }
    }

    private final class DelayedEndSession: VoiceSessionRegistrySession, @unchecked Sendable {
        let gate: EndGate
        var id: String? = "delayed-end"

        init(gate: EndGate) { self.gate = gate }

        var rishiSessionId: String? { get async { id } }
        func parkForBackground() async {}
        func resumeFromBackground() async {}

        func end() async -> String? {
            await gate.markStarted()
            await gate.waitForRelease()
            return id
        }
    }

    @Test("registration and park/resume retain one session and reset expiry")
    func registrationParkResume() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let session = FakeSession()
        let userID = UUID()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .milliseconds(80),
            currentUserIDProvider: { userID },
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
        let userID = UUID()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .milliseconds(20),
            currentUserIDProvider: { userID },
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
        let userID = UUID()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            gracePeriod: .seconds(60),
            currentUserIDProvider: { userID },
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
        let userID = UUID()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            currentUserIDProvider: { userID },
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

    @Test("waitForServerEnd waits while local close is still awaiting transport end")
    func waitForServerEndCoversTheWholeCloseFlight() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let gate = EndGate()
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            currentUserIDProvider: { UUID() },
            endServerSession: { _ in }
        )
        await registry.register(DelayedEndSession(gate: gate))

        let closeTask = Task { await registry.close() }
        while !(await gate.started) { await Task.yield() }

        let completion = CompletionFlag()
        let waitTask = Task {
            await registry.waitForServerEnd()
            await completion.markComplete()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await completion.value == false)

        await gate.release()
        await closeTask.value
        await waitTask.value
        #expect(await completion.value == true)
    }

    @Test("a pending end ID from another account is never exposed")
    func pendingEndIDIsAccountScoped() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let oldUserID = UUID()
        let currentUserID = UUID()
        let oldRegistry = VoiceSessionRegistry(
            defaults: defaults,
            currentUserIDProvider: { oldUserID }
        )
        oldRegistry.persistedServerSessionID = "old-account-session"
        let registry = VoiceSessionRegistry(
            defaults: defaults,
            currentUserIDProvider: { currentUserID }
        )

        #expect(registry.persistedServerSessionID == nil)
        #expect(oldRegistry.persistedServerSessionID == "old-account-session")
    }
}

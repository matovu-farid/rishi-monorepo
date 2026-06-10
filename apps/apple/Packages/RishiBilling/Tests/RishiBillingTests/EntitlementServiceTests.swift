import Testing
import Foundation
@testable import RishiBilling
import RishiAPI

@Suite(.serialized)
struct EntitlementServiceTests {

    // MARK: - Helpers

    /// Build a fresh, isolated UserDefaults suite per test so tests can run in
    /// parallel without bleeding cache state into one another.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// Test-only WorkerClient pointing at an invalid host. Unit tests in this
    /// suite never actually exercise `refresh()` against the network — the
    /// integration coverage lives in 11-06 with StubURLProtocol.
    private func makeWorkerClient() -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    // MARK: - EntitlementLevel model

    @Test("EntitlementLevel rawValues are stable")
    func entitlementLevelRawValuesStable() {
        #expect(EntitlementLevel.free.rawValue == "free")
        #expect(EntitlementLevel.pro.rawValue == "pro")
    }

    @Test("EntitlementLevel(hasPro:) maps booleans correctly")
    func entitlementLevelFromHasPro() {
        #expect(EntitlementLevel(hasPro: true) == .pro)
        #expect(EntitlementLevel(hasPro: false) == .free)
    }

    // MARK: - EntitlementService cache hydration

    @Test("Service hydrates from UserDefaults on init")
    func serviceHydratesFromDefaults() async {
        let defaults = makeDefaults()
        defaults.set("pro", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .pro)
    }

    @Test("Missing UserDefaults key defaults to .free")
    func missingCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .free)
    }

    @Test("Unknown rawValue in UserDefaults falls back to .free")
    func corruptCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        defaults.set("enterprise-ultra", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .free)
    }

    // MARK: - setCached

    @Test("setCached updates snapshot and persists to UserDefaults")
    func setCachedPersists() async {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        await service.setCached(.pro)
        let snap = await service.snapshot()
        #expect(snap == .pro)

        // Re-open the same suite by name to read the persisted value from a
        // fresh, isolation-safe handle (Swift 6 strict concurrency dislikes
        // touching `defaults` after we sent it into the actor).
        let reader = UserDefaults(suiteName: suiteName)!
        #expect(reader.string(forKey: "billing.entitlement.level") == "pro")
    }

    // MARK: - AsyncStream

    @Test("currentLevel stream yields cached value to first subscriber")
    func currentLevelYieldsCachedValue() async {
        let defaults = makeDefaults()
        defaults.set("pro", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)

        var iter = service.currentLevel.makeAsyncIterator()
        let first = await iter.next()
        #expect(first == .pro)
    }
}

import Testing
import Foundation
@testable import RishiSettings

@Suite(.serialized)
struct TelemetryStoreTests {

    actor RecordingSink: TelemetrySink {
        private(set) var lastValue: Bool?
        func setEnabled(_ enabled: Bool) async { lastValue = enabled }
        func observed() -> Bool? { lastValue }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.telemetry.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Default opted-in state is TRUE on first run")
    func defaultIsTrue() async {
        let store = UserDefaultsTelemetryStore(defaults: freshDefaults())
        #expect(await store.optedIn() == true)
    }

    @Test("setOptedIn(false) persists FALSE to UserDefaults")
    func setOptedInPersistsFalse() async {
        let d = freshDefaults()
        let store = UserDefaultsTelemetryStore(defaults: d)
        await store.setOptedIn(false)
        #expect(await store.optedIn() == false)
        #expect(d.bool(forKey: UserDefaultsTelemetryStore.storageKey) == false)
    }

    @Test("setOptedIn invokes the sink with the new value")
    func setOptedInCallsSink() async {
        let sink = RecordingSink()
        let store = UserDefaultsTelemetryStore(defaults: freshDefaults(), sink: sink)
        await store.setOptedIn(false)
        #expect(await sink.observed() == false)
        await store.setOptedIn(true)
        #expect(await sink.observed() == true)
    }

    @Test("InMemoryTelemetryStore round-trips initial value")
    func inMemoryRoundTrips() async {
        let store = InMemoryTelemetryStore(initial: false)
        #expect(await store.optedIn() == false)
        await store.setOptedIn(true)
        #expect(await store.optedIn() == true)
    }
}

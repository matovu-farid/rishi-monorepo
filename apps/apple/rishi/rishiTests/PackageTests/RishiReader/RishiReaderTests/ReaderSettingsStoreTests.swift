@testable import rishi
import Testing
import Foundation



@Suite("ReaderSettingsStore (UserDefaults)", .serialized)
struct ReaderSettingsStoreTests {

    /// A fresh, isolated UserDefaults suite per test — avoids cross-test
    /// pollution AND keeps the host's `.standard` defaults pristine.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ReaderSettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Returns default theme when nothing persisted")
    func returnsDefaultThemeWhenNothingPersisted() async {
        let store = UserDefaultsReaderSettingsStore(defaults: makeDefaults())
        let bookId: BookID = UUID()
        let theme = await store.theme(for: bookId)
        #expect(theme == .default)
    }

    @Test("Round-trips theme per book ID")
    func roundTripsThemePerBookID() async {
        let store = UserDefaultsReaderSettingsStore(defaults: makeDefaults())
        let alice: BookID = UUID()
        let wonderland: BookID = UUID()
        await store.setTheme(.sepia, for: alice)
        await store.setTheme(.dark,  for: wonderland)
        #expect(await store.theme(for: alice)      == .sepia)
        #expect(await store.theme(for: wonderland) == .dark)
    }

    @Test("Overwrites previous value")
    func overwritesPreviousValue() async {
        let store = UserDefaultsReaderSettingsStore(defaults: makeDefaults())
        let bookId: BookID = UUID()
        await store.setTheme(.sepia, for: bookId)
        await store.setTheme(.dark,  for: bookId)
        #expect(await store.theme(for: bookId) == .dark)
    }

    @Test("Honors custom namespace (key prefix)")
    func honorsCustomNamespace() async {
        let defaults = makeDefaults()
        let store = UserDefaultsReaderSettingsStore(defaults: defaults, namespace: "custom.ns")
        let bookId: BookID = UUID()
        await store.setTheme(.dark, for: bookId)
        let expectedKey = "custom.ns.\(bookId.uuidString).theme"
        #expect(defaults.string(forKey: expectedKey) == "dark")
    }

    @Test("persistedTheme and peek return nil when empty")
    func persistedThemeAndPeekReturnNilWhenEmpty() async {
        let store = UserDefaultsReaderSettingsStore(defaults: makeDefaults())
        let bookId: BookID = UUID()
        #expect(store.peekPersistedTheme(for: bookId) == nil)
        #expect(await store.persistedTheme(for: bookId) == nil)
    }

    @Test("Round-trips matchDevice via persistedTheme and peek")
    func roundTripsMatchDeviceViaPersistedThemeAndPeek() async {
        let store = UserDefaultsReaderSettingsStore(defaults: makeDefaults())
        let bookId: BookID = UUID()
        await store.setTheme(.matchDevice, for: bookId)
        #expect(store.peekPersistedTheme(for: bookId) == .matchDevice)
        #expect(await store.persistedTheme(for: bookId) == .matchDevice)
        #expect(await store.theme(for: bookId) == .matchDevice)
    }


}

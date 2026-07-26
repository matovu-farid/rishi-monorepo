@testable import rishi
import Testing
import Foundation



@Suite("PDFThemePicker persistence", .serialized)
struct PDFThemePickerTests {

    @Test("Selecting a theme persists through ReaderSettingsStore")
    func selectionPersists() async {
        let suite = "ThemePickerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsReaderSettingsStore(defaults: defaults)

        let bookId = BookID()
        let initial = await store.theme(for: bookId)
        #expect(initial == .default)

        await store.setTheme(.sepia, for: bookId)
        #expect(await store.theme(for: bookId) == .sepia)

        await store.setTheme(.dark, for: bookId)
        #expect(await store.theme(for: bookId) == .dark)
    }

    @Test("Theme persists across a fresh store instance (close/reopen contract)")
    func themePersistsAcrossInstances() async {
        let suite = "ThemePickerTests-reopen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let bookId = BookID()
        let firstStore = UserDefaultsReaderSettingsStore(defaults: defaults)
        await firstStore.setTheme(.sepia, for: bookId)

        // Simulate close + reopen: build a NEW store backed by the same defaults.
        let secondStore = UserDefaultsReaderSettingsStore(defaults: defaults)
        #expect(await secondStore.theme(for: bookId) == .sepia)
    }
}

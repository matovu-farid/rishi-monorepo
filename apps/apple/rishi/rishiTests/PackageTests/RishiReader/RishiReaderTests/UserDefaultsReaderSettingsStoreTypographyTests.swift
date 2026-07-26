@testable import rishi
import Testing
import Foundation



@Suite("UserDefaultsReaderSettingsStore typography", .serialized)
struct UserDefaultsReaderSettingsStoreTypographyTests {

    private func freshStore() -> (UserDefaultsReaderSettingsStore, UserDefaults, String) {
        let suite = "TypographyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (UserDefaultsReaderSettingsStore(defaults: defaults), defaults, suite)
    }

    @Test("typography(for:) returns default when nothing persisted")
    func defaultWhenEmpty() async {
        let (store, _, _) = freshStore()
        let bookId = BookID()
        let result = await store.typography(for: bookId)
        #expect(result.fontFamily == .system)
        #expect(result.lineHeight.multiplier == 1.4)
    }

    @Test("setTypography round-trips through a fresh read")
    func setTypographyRoundTrips() async {
        let (store, _, _) = freshStore()
        let bookId = BookID()
        let typography = ReaderTypography(
            fontFamily: .dyslexic,
            fontSize: ReaderFontSize(points: 22),
            lineHeight: ReaderLineHeight(multiplier: 1.6)
        )
        await store.setTypography(typography, for: bookId)
        let read = await store.typography(for: bookId)
        #expect(read.fontFamily == .dyslexic)
        #expect(read.fontSize.points == 22)
        #expect(read.lineHeight.multiplier == 1.6)
    }

    @Test("Theme and typography for the same book don't collide")
    func themeAndTypographyIndependent() async {
        let (store, _, _) = freshStore()
        let bookId = BookID()
        await store.setTheme(.sepia, for: bookId)
        await store.setTypography(ReaderTypography(
            fontFamily: .serif,
            fontSize: ReaderFontSize(points: 18),
            lineHeight: ReaderLineHeight(multiplier: 1.5)
        ), for: bookId)

        #expect(await store.theme(for: bookId) == .sepia)
        let t = await store.typography(for: bookId)
        #expect(t.fontFamily == .serif)
        #expect(t.fontSize.points == 18)
    }

    @Test("Out-of-range stored values are clamped on read")
    func clampOnRead() async {
        let (store, defaults, _) = freshStore()
        let bookId = BookID()
        // Stuff out-of-range raw values past the writer's clamp by
        // poking UserDefaults directly.
        defaults.set(99.0, forKey: "reader.settings.\(bookId.uuidString).font.size")
        defaults.set(0.1, forKey: "reader.settings.\(bookId.uuidString).font.lineHeight")
        let t = await store.typography(for: bookId)
        #expect(t.fontSize.points == 32)        // clamped to max
        #expect(t.lineHeight.multiplier == 1.0) // clamped to min
    }
}

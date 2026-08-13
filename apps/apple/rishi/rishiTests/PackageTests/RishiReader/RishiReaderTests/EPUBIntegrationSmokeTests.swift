@testable import rishi
import Testing
import Foundation
import ReadiumShared




/// Phase 6 end-to-end integration smoke. Runs entirely against the bundled
/// `alice.epub` (Resources/Bundled/alice.epub from plan 06-01).
///
/// Covers the four Phase 6 ROADMAP success criteria as far as a unit-test
/// process can:
///   1. Open + change page + persist position → reopen → restored.
///   2. Typography + theme mutations persist through `ReaderSettingsStore`
///      across distinct VM instances (matches what the screen does on
///      `.task` after `load()`).
///   3. Highlights survive close → reopen.
///   4. The bundled resource is shaped correctly (small enough to ship,
///      non-empty).
///
/// Visual rendering, two-page spread, and Readium preferences submission
/// are validated by Spike A's hardware run and the orchestrator's
/// xcodebuild iOS Sim + Mac Catalyst build verification — they need a
/// real UIWindow / WKWebView pipeline that XCTest unit targets can't
/// reach without spinning XCUITest.
@Suite("Phase 6 EPUB integration smoke", .serialized)
struct EPUBIntegrationSmokeTests {

    private func aliceURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
    }

    @Test("Bundled alice.epub is small and non-empty")
    func bundledAliceExists() throws {
        let url = try aliceURL()
        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        #expect(data.count < 250_000)
    }

    @Test("End-to-end: load → typography persist → page change → flush → reopen → position restored")
    func endToEndRoundTrip() async throws {
        let url = try aliceURL()
        let positionStore = InMemoryPositionStore()
        let suite = "EPUBE2E-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settingsStore = UserDefaultsReaderSettingsStore(defaults: defaults)
        let userId = UUID()
        let book = Book(userId: userId, title: "Alice", formatType: .epub, fileURL: "x")

        // ----- First open: load, mutate typography + theme, change page, flush

        let vm1 = ReaderViewModel(
            book: book,
            userId: userId,
            documentURL: url,
            positionStore: positionStore,
            debounceSeconds: 0.05
        )
        await vm1.load()
        #expect(vm1.publication != nil)

        let updatedTypography = ReaderTypography(
            fontFamily: .serif,
            fontSize: ReaderFontSize(points: 20),
            lineHeight: ReaderLineHeight(multiplier: 1.6)
        )
        await settingsStore.setTypography(updatedTypography, for: book.id)
        await settingsStore.setTheme(.sepia, for: book.id)

        // Simulate a navigator page change by synthesising a locator at
        // 30% progress on the first reading-order entry — exactly what
        // EPUBNavigatorDelegate.locationDidChange would forward.
        let firstLink = try #require(vm1.publication?.readingOrder.first)
        let locator = Locator(
            href: RelativeURL(path: firstLink.href)!,
            mediaType: firstLink.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: 0.3, totalProgression: 0.3)
        )
        vm1.didChangeLocation(locator)
        await vm1.flush()

        // ----- Second open: fresh VM, hydrate settings from store, confirm
        //       latestLocator is non-nil after load() and settings round-trip.

        let vm2 = ReaderViewModel(
            book: book,
            userId: userId,
            documentURL: url,
            positionStore: positionStore,
            debounceSeconds: 0.05
        )
        await vm2.load()
        vm2.typography = await settingsStore.typography(for: book.id)
        vm2.theme = await settingsStore.theme(for: book.id)

        let restoredLocator = try #require(vm2.latestLocator)
        #expect(restoredLocator.href == locator.href)
        #expect(restoredLocator.locations.progression == locator.locations.progression)
        let readAloudStartLocator = try #require(await vm2.readAloudStartLocator())
        #expect(readAloudStartLocator.href == locator.href)
        #expect(readAloudStartLocator.locations.progression == locator.locations.progression)
        #expect(vm2.typography.fontFamily == .serif)
        #expect(vm2.typography.fontSize.points == 20)
        #expect(vm2.theme == .sepia)
    }

    @Test("Highlights survive close → reopen")
    func highlightsSurviveReopen() async throws {
        let url = try aliceURL()
        let positionStore = InMemoryPositionStore()
        let highlightStore = InMemoryHighlightStore()
        let userId = UUID()
        let book = Book(userId: userId, title: "Alice", formatType: .epub, fileURL: "x")

        let vm1 = ReaderViewModel(
            book: book,
            userId: userId,
            documentURL: url,
            positionStore: positionStore,
            debounceSeconds: 0.05
        )
        await vm1.load()
        let inner = Locator(
            href: RelativeURL(path: "chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.4),
            text: Locator.Text(highlight: "down the rabbit hole")
        )
        let locator = EPUBHighlightLocator(locator: inner)
        let created = try #require(await vm1.createHighlight(
            color: .yellow,
            locator: locator,
            note: "first highlight",
            store: highlightStore
        ))
        #expect(created.note == "first highlight")

        let vm2 = ReaderViewModel(
            book: book,
            userId: userId,
            documentURL: url,
            positionStore: positionStore,
            debounceSeconds: 0.05
        )
        await vm2.load()
        await vm2.loadHighlights(from: highlightStore)
        #expect(vm2.loadedHighlights.count == 1)
        #expect(vm2.loadedHighlights.first?.note == "first highlight")
        let decoded = try EPUBHighlightLocator.decode(jsonString: vm2.loadedHighlights[0].locatorStart)
        #expect(decoded.text == "down the rabbit hole")
    }
}

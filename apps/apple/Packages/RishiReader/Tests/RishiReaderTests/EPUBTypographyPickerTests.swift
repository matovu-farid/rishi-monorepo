import Testing
import Foundation
import RishiCore
@testable import RishiReader

/// Persistence tests for ``EPUBTypographyPicker``. We don't render SwiftUI
/// — the picker is a thin shell over `ReaderSettingsStore.setTypography`
/// + a `Binding<ReaderTypography>`. We verify the contract the picker
/// commits to: every selection round-trips through the store, and the
/// default font size comes out inside the clamp window (Dynamic-Type-
/// derived on UIKit, 17pt elsewhere — EPUB-09).
@Suite("EPUBTypographyPicker persistence", .serialized)
struct EPUBTypographyPickerTests {

    @Test("Setting font family / size / line height persists through ReaderSettingsStore")
    func selectionPersists() async {
        let suite = "TypographyPickerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsReaderSettingsStore(defaults: defaults)
        let bookId = BookID()

        // Simulate picker mutations: each slider / button tap eventually
        // calls `setTypography(_:for:)` with the new composite value.
        let updated = ReaderTypography(
            fontFamily: .dyslexic,
            fontSize: ReaderFontSize(points: 24),
            lineHeight: ReaderLineHeight(multiplier: 1.8)
        )
        await store.setTypography(updated, for: bookId)

        let read = await store.typography(for: bookId)
        #expect(read.fontFamily == .dyslexic)
        #expect(read.fontSize.points == 24)
        #expect(read.lineHeight.multiplier == 1.8)
    }

    @Test("Default typography exposes a font size inside the clamp window (EPUB-09)")
    func defaultUsesDynamicType() {
        let defaultSize = ReaderTypography.default.fontSize
        #expect(defaultSize.points >= ReaderFontSize.min)
        #expect(defaultSize.points <= ReaderFontSize.max)
    }
}

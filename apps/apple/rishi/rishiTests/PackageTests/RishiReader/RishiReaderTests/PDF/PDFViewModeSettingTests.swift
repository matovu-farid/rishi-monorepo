@testable import rishi
import Testing


/// Unit coverage for the user-facing 4-case PDF view-mode setting: case count,
/// stable raw values (persisted to UserDefaults in Wave 4 — must not drift),
/// rawValue round-trip + nil fallback, and non-empty display names. The enum is
/// pure (no PDFKit/UIKit), so the whole surface is verified here on the dev host.
@Suite("PDFViewModeSetting")
struct PDFViewModeSettingTests {

    @Test("exactly four cases exist")
    func fourCases() {
        #expect(PDFViewModeSetting.allCases.count == 4)
    }

    @Test("raw values are stable persistence keys")
    func stableRawValues() {
        #expect(PDFViewModeSetting.automatic.rawValue == "automatic")
        #expect(PDFViewModeSetting.singlePage.rawValue == "singlePage")
        #expect(PDFViewModeSetting.continuous.rawValue == "continuous")
        #expect(PDFViewModeSetting.twoPage.rawValue == "twoPage")
    }

    @Test("rawValue round-trips every case")
    func rawValueRoundTrip() {
        for mode in PDFViewModeSetting.allCases {
            #expect(PDFViewModeSetting(rawValue: mode.rawValue) == mode)
        }
    }

    @Test("unknown rawValue is nil so callers can fall back to .automatic")
    func unknownRawValueIsNil() {
        #expect(PDFViewModeSetting(rawValue: "garbage") == nil)
    }

    @Test("default is automatic")
    func defaultIsAutomatic() {
        #expect(PDFViewModeSetting.default == .automatic)
    }

    @Test("every case has a non-empty, expected display name")
    func displayNames() {
        #expect(PDFViewModeSetting.automatic.displayName == "Automatic")
        #expect(PDFViewModeSetting.singlePage.displayName == "Single Page")
        #expect(PDFViewModeSetting.continuous.displayName == "Continuous")
        #expect(PDFViewModeSetting.twoPage.displayName == "Two Page")
        for mode in PDFViewModeSetting.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }
}

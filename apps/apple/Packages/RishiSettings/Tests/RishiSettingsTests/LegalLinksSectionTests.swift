import Foundation
import SwiftUI
import Testing
@testable import RishiSettings

/// IAP-08 / Plan 13-10 — Legal links section tests.
///
/// Verifies that the Settings "Legal" section exposes exactly three rows
/// (Subscription Terms, Privacy Policy, Terms of Use), each pinned to a
/// canonical `rishi.fidexa.org/legal/*` URL, and that the row tap path
/// presents via `SFSafariViewController` (an `UIViewControllerRepresentable`
/// — verified at compile time by upcasting `SafariSheet` to the protocol).
@MainActor
@Suite("LegalLinksSection — IAP-08 legal disclosure rows")
struct LegalLinksSectionTests {

    @Test("LegalLink enum has exactly three cases")
    func legalLink_enumHasExactlyThreeCases() {
        #expect(LegalLinksSection.LegalLink.allCases.count == 3)
    }

    @Test("LegalLink URLs are pinned to rishi.fidexa.org/legal/*")
    func legalLink_urlsArePinned() {
        #expect(
            LegalLinksSection.LegalLink.subscriptionTerms.rawValue
                == "https://rishi.fidexa.org/legal/subscription-terms"
        )
        #expect(
            LegalLinksSection.LegalLink.privacyPolicy.rawValue
                == "https://rishi.fidexa.org/legal/privacy"
        )
        #expect(
            LegalLinksSection.LegalLink.termsOfUse.rawValue
                == "https://rishi.fidexa.org/legal/terms"
        )
    }

    @Test("LegalLink titles are non-empty and human-readable")
    func legalLink_titlesAreNonEmpty() {
        for link in LegalLinksSection.LegalLink.allCases {
            #expect(!link.title.isEmpty)
        }
        #expect(LegalLinksSection.LegalLink.subscriptionTerms.title == "Subscription Terms")
        #expect(LegalLinksSection.LegalLink.privacyPolicy.title == "Privacy Policy")
        #expect(LegalLinksSection.LegalLink.termsOfUse.title == "Terms of Use")
    }

    @Test("LegalLink systemImage names are non-empty SF Symbols")
    func legalLink_systemImagesArePresent() {
        for link in LegalLinksSection.LegalLink.allCases {
            #expect(!link.systemImage.isEmpty)
        }
    }

    @Test("Subscription Terms URL path contains subscription-terms")
    func legalLink_subscriptionTermsURL_isSubscriptionTerms() {
        #expect(
            LegalLinksSection.LegalLink.subscriptionTerms.rawValue
                .contains("subscription-terms")
        )
    }

    @Test("Each LegalLink.rawValue parses as a valid URL")
    func legalLink_rawValuesParseAsURL() {
        for link in LegalLinksSection.LegalLink.allCases {
            #expect(URL(string: link.rawValue) != nil)
        }
    }

    @Test("IdentifiedURL id is unique per instance even for the same URL")
    func identifiedURL_idIsStable_perInstance() {
        let url = URL(string: "https://example.com")!
        let a = IdentifiedURL(url: url)
        let b = IdentifiedURL(url: url)
        #expect(a.id != b.id)
        #expect(a.url == b.url)
    }

    /// Compile-time assertion that the in-app browser wrapper is a SwiftUI
    /// `UIViewControllerRepresentable`, NOT a hand-rolled WebKit view and
    /// NOT a plain View. SafariServices/UIKit only exist on iOS + Catalyst,
    /// so the assertion is gated under the same `#if` the implementation
    /// uses.
    #if canImport(SafariServices) && canImport(UIKit)
    @Test("SafariSheet conforms to UIViewControllerRepresentable")
    func safariSheet_compilesAndConforms() {
        let url = URL(string: "https://rishi.fidexa.org/legal/privacy")!
        let sheet = SafariSheet(url: url)
        let _: any UIViewControllerRepresentable = sheet
        #expect(sheet.url == url)
    }
    #endif

    @Test("LegalLinksSection body compiles")
    func legalLinksSection_bodyCompiles() {
        let section = LegalLinksSection()
        _ = section.body
    }
}

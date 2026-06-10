import Testing
import Foundation
@testable import RishiReader

@Suite("EPUB Readium link smoke")
struct EPUBReadiumLinkSmokeTests {

    @Test("linkProof references at least 6 Readium types")
    func linkProofMentionsReadiumTypes() {
        let proof = EPUBReadiumImport.linkProof()
        let parts = proof.split(separator: ",")
        #expect(parts.count >= 6)
        // Spot-check: Publication is the entry type
        #expect(proof.contains("Publication"))
        #expect(proof.contains("AssetRetriever"))
        #expect(proof.contains("PublicationOpener"))
        #expect(proof.contains("Locator"))
    }

    #if canImport(UIKit)
    @Test("EPUBNavigatorViewController + Decoration symbols are linked on UIKit")
    func navigatorSymbolsLinkOnUIKit() {
        let proof = EPUBReadiumImport.linkProof()
        #expect(proof.contains("EPUBNavigatorViewController"))
        #expect(proof.contains("Decoration"))
    }
    #endif
}

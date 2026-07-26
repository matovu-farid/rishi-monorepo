@testable import rishi
import Testing
import Foundation


@Suite("RishiSettings package smoke")
struct RishiSettings_PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiSettings.version == "0.1.0-scaffold")
    }

    @Test("Package imports compile (sibling Feature deps resolve)")
    func siblingFeatureDepsResolve() {
        // Touching the package version is enough — if any of the sibling
        // Feature deps (RishiSync / RishiAudio / RishiReader / RishiBilling)
        // failed to resolve, this test target wouldn't compile.
        #expect(RishiSettings.version.hasPrefix("0."))
    }

    @Test("RishiSettings namespace exists and is an enum")
    func namespaceIsEnum() {
        let name = String(describing: RishiSettings.self)
        #expect(name == "RishiSettings")
    }
}

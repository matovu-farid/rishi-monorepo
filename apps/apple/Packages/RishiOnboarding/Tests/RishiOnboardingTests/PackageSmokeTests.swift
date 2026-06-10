import Testing
import Foundation
@testable import RishiOnboarding
import RishiCore
import RishiLibrary

@Suite("RishiOnboarding package smoke")
struct PackageSmokeTests {

    @Test("Version string is the scaffold marker")
    func versionStringIsScaffoldMarker() {
        #expect(RishiOnboarding.version == "0.1.0-scaffold")
    }

    @Test("RishiCore User is reachable")
    func rishiCoreUserIsReachable() {
        let user = User(
            id: UUID(),
            email: "onb@example.com",
            displayName: nil,
            avatarURL: nil,
            hasPro: false,
            createdAt: Date()
        )
        #expect(user.email == "onb@example.com")
    }

    @Test("RishiLibrary SampleBookInstaller type is reachable")
    func rishiLibrarySampleInstallerIsReachable() {
        let typeName = String(describing: SampleBookInstaller.self)
        #expect(typeName == "SampleBookInstaller")
    }
}

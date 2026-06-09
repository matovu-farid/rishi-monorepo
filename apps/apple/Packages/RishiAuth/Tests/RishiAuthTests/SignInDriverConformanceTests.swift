import Foundation
import Testing
import RishiCore
import RishiAPI
@testable import RishiAuth

/// Verifies that the concrete coordinator actors conform to the driver
/// protocols. Conformance is exercised purely by the type checker — if the
/// retroactive `extension … : AppleSignInDriver {}` is missing the test won't
/// compile.
@Suite("SignInDriver — concrete-actor conformance")
struct SignInDriverConformanceTests {

    @Test func appleCoordinatorConformsToAppleSignInDriver() {
        func requireDriver<T: AppleSignInDriver>(_ type: T.Type) {}
        requireDriver(SignInWithAppleCoordinator.self)
    }

    @Test func googleCoordinatorConformsToGoogleSignInDriver() {
        func requireDriver<T: GoogleSignInDriver>(_ type: T.Type) {}
        requireDriver(GoogleSignInCoordinator.self)
    }
}

import Foundation
import Testing
import RishiCore
import RishiCore
@testable import RishiAuth

/// Verifies that the concrete coordinator actor conforms to the driver
/// protocol. Conformance is exercised purely by the type checker — if the
/// retroactive `extension … : AppleSignInDriver {}` is missing the test won't
/// compile.
@Suite("SignInDriver — concrete-actor conformance")
struct SignInDriverConformanceTests {

    @Test func appleCoordinatorConformsToAppleSignInDriver() {
        func requireDriver<T: AppleSignInDriver>(_ type: T.Type) {}
        requireDriver(SignInWithAppleCoordinator.self)
    }
}

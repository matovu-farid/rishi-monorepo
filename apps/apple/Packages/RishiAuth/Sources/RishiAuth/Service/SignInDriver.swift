import Foundation

// MARK: - Driver seams

/// Internal seam so ``RishiAuthService`` can be tested with mock implementations
/// instead of the concrete coordinator actors. ``SignInWithAppleCoordinator``
/// (plan 03-03) gains conformance via the retroactive extension below.
public protocol AppleSignInDriver: Sendable {
    func signIn() async throws -> Session
}

/// Internal seam so ``RishiAuthService`` can be tested with mock implementations
/// instead of the concrete coordinator actors. ``GoogleSignInCoordinator``
/// (plan 03-04) gains conformance via the retroactive extension below.
public protocol GoogleSignInDriver: Sendable {
    func signIn() async throws -> Session
}

// MARK: - Concrete-actor conformances
//
// The coordinator actors already expose `func signIn() async throws -> Session`
// — these one-line extensions simply tell the type system they satisfy the
// driver protocols. Keeping the conformances in this file (rather than next to
// each coordinator) means the protocols and their adopters live together, so
// any drift in signatures is a single-file fix.

extension SignInWithAppleCoordinator: AppleSignInDriver {}
extension GoogleSignInCoordinator: GoogleSignInDriver {}

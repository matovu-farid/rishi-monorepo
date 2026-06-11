import Foundation

// MARK: - Driver seams

/// Internal seam so ``RishiAuthService`` can be tested with mock implementations
/// instead of the concrete coordinator actor. ``SignInWithAppleCoordinator``
/// (plan 03-03) gains conformance via the retroactive extension below.
public protocol AppleSignInDriver: Sendable {
    func signIn() async throws -> Session
}

// MARK: - Concrete-actor conformances
//
// The coordinator actor already exposes `func signIn() async throws -> Session`
// — this one-line extension simply tells the type system it satisfies the
// driver protocol. Keeping the conformance in this file (rather than next to
// the coordinator) means the protocol and its adopter live together, so any
// drift in signatures is a single-file fix.
//
// Phase 15 plan 15-03: legacy secondary-provider driver protocol was
// hard-removed alongside its coordinator — SIWA is the sole social
// provider for v1.

extension SignInWithAppleCoordinator: AppleSignInDriver {}

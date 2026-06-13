import Foundation

/// Public namespace for the RishiAuth package. Concrete implementations
/// (KeychainSessionStore, SignInWithAppleCoordinator, RishiAuthService,
/// RishiAuthTokenProvider) are added in plans 03-02..03-05.
/// Phase 15 plan 15-03: secondary social-provider coordinator hard-removed
/// (Apple-only v1).
enum RishiAuth {

    /// Marker for the public RishiAuth API version. Bump when the surface breaks.
    static let apiVersion = "0.1.0-scaffold"
}

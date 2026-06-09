import Foundation

/// Public namespace for the RishiAuth package. Concrete implementations
/// (KeychainSessionStore, SignInWithAppleCoordinator, GoogleSignInCoordinator,
/// RishiAuthService, RishiAuthTokenProvider) are added in plans 03-02..03-05.
public enum RishiAuth {

    /// Marker for the public RishiAuth API version. Bump when the surface breaks.
    public static let apiVersion = "0.1.0-scaffold"
}

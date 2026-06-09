import Foundation

public protocol AuthService: Sendable {
    /// The current authenticated user, or nil if signed out.
    var currentUser: User? { get async }

    /// Begin Sign in with Apple. Returns the freshly authenticated user.
    func signInWithApple() async throws -> User

    /// Begin Google OAuth via ASWebAuthenticationSession. Returns the freshly authenticated user.
    func signInWithGoogle() async throws -> User

    /// Clear the local session.
    func signOut() async throws

    /// Delete the user's account end-to-end (worker-side revocation + local cleanup).
    func deleteAccount() async throws
}

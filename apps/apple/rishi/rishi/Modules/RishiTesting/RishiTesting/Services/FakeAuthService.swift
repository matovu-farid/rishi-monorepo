import Foundation


public actor FakeAuthService: AuthService {
    public private(set) var preconfiguredUser: User?
    public private(set) var signInAppleCallCount: Int = 0
    public private(set) var signOutCallCount: Int = 0
    public private(set) var deleteAccountCallCount: Int = 0

    public init(currentUser: User? = nil) {
        self.preconfiguredUser = currentUser
    }

    public var currentUser: User? {
        get async { preconfiguredUser }
    }

    public func signInWithApple() async throws -> User {
        signInAppleCallCount += 1
        if let u = preconfiguredUser { return u }
        let u = User.fixture(email: "siwa.fixture@example.com")
        preconfiguredUser = u
        return u
    }

    public func signOut() async throws {
        signOutCallCount += 1
        preconfiguredUser = nil
    }

    public func deleteAccount() async throws {
        deleteAccountCallCount += 1
        preconfiguredUser = nil
    }

    /// Test affordance: directly set the user (e.g. to simulate a pre-existing session).
    public func setUser(_ user: User?) {
        preconfiguredUser = user
    }
}

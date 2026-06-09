import Foundation
import Testing
@testable import RishiAPI

@Suite("Endpoint Codable + path correctness")
struct EndpointCodableTests {

    // MARK: - Auth

    @Test func googleSignInPathAndBody() throws {
        let e = GoogleSignInEndpoint(body: .init(idToken: "tok"))
        #expect(e.method == .POST)
        #expect(e.path == "/api/auth/google")
        let data = try JSONEncoder().encode(e.body)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"id_token\""))
        #expect(json.contains("\"tok\""))
    }

    @Test func appleSignInIncludesPrivateRelayFriendlyOptionals() throws {
        let body = AppleSignInEndpoint.Body(
            identityToken: "idtok",
            authorizationCode: "code",
            user: "001234.user",
            fullName: nil,
            email: nil
        )
        let json = String(data: try JSONEncoder().encode(body), encoding: .utf8) ?? ""
        #expect(json.contains("\"identity_token\""))
        #expect(json.contains("\"authorization_code\""))
        let e = AppleSignInEndpoint(body: body)
        #expect(e.path == "/api/auth/apple")
    }

    @Test func authSessionResponseDecodes() throws {
        let json = #"{"session_token":"s","user_id":"u","email":"x@y"}"#
        let r = try JSONDecoder().decode(AuthSessionResponse.self, from: Data(json.utf8))
        #expect(r.sessionToken == "s")
        #expect(r.userId == "u")
        #expect(r.email == "x@y")
    }

    @Test func getSessionResponseDecodes() throws {
        let json = #"""
        {"user":{"id":"u","email":"x@y","display_name":null,"avatar_url":null},"has_pro":true}
        """#
        let r = try JSONDecoder().decode(GetSessionEndpoint.ProfileResponse.self, from: Data(json.utf8))
        #expect(r.hasPro == true)
        #expect(r.user.id == "u")
        #expect(r.user.displayName == nil)
    }

    @Test func signOutAndDeleteUserPathsAreCorrect() {
        #expect(SignOutEndpoint().path == "/api/auth/sign-out")
        #expect(DeleteUserEndpoint().path == "/api/auth/delete-user")
        #expect(GetSessionEndpoint().method == .GET)
    }

    @Test func okResponseDecodes() throws {
        let r = try JSONDecoder().decode(OkResponse.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(r.ok == true)
    }

    @Test func sessionUserRoundTripsThroughCodable() throws {
        let original = SessionUser(id: "u", email: "x@y", displayName: "Display", avatarURL: "https://avatar")
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"display_name\""))
        #expect(json.contains("\"avatar_url\""))
        let decoded = try JSONDecoder().decode(SessionUser.self, from: data)
        #expect(decoded == original)
    }
}

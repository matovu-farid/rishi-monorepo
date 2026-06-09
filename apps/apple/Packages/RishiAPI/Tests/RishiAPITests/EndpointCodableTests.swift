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

    // MARK: - Realtime + Audio

    @Test func realtimeClientSecretsQueryAppended() {
        let e = RealtimeClientSecretsEndpoint(language: "en")
        #expect(e.path == "/api/realtime/client_secrets?language=en")
        let bare = RealtimeClientSecretsEndpoint()
        #expect(bare.path == "/api/realtime/client_secrets")
        #expect(e.method == .GET)
    }

    @Test func realtimeClientSecretsResponseDecodes() throws {
        let json = #"{"client_secret":"sec","session_id":"sid"}"#
        let r = try JSONDecoder().decode(RealtimeClientSecretsEndpoint.ClientSecretResponse.self, from: Data(json.utf8))
        #expect(r.clientSecret == "sec")
        #expect(r.sessionId == "sid")
    }

    @Test func realtimeUsagePostsSnakeCaseBody() throws {
        let body = RealtimeUsageEndpoint.Body(sessionId: "x", durationSeconds: 30, charactersGenerated: 500)
        let json = String(data: try JSONEncoder().encode(body), encoding: .utf8) ?? ""
        #expect(json.contains("\"session_id\""))
        #expect(json.contains("\"duration_seconds\""))
        #expect(json.contains("\"characters_generated\""))
        let e = RealtimeUsageEndpoint(body: body)
        #expect(e.path == "/api/realtime/usage")
        #expect(e.method == .POST)
    }

    @Test func speechStreamEndpointShape() throws {
        let e = SpeechStreamEndpoint(body: .init(text: "hi", voice: "alloy", speed: 1.0))
        #expect(e.path == "/api/audio/speech")
        #expect(e.method == .POST)
        let json = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(json.contains("\"text\""))
        #expect(json.contains("\"voice\""))
        #expect(json.contains("\"speed\""))
    }

    @Test func transcribeEndpointShape() throws {
        let e = TranscribeEndpoint(body: .init(audio: Data([0xFF, 0xFB]), mimeType: "audio/mp3"))
        #expect(e.path == "/api/audio/transcribe")
        #expect(e.method == .POST)
        let json = #"{"transcript":"hello world"}"#
        let r = try JSONDecoder().decode(TranscribeEndpoint.TranscribeResponse.self, from: Data(json.utf8))
        #expect(r.transcript == "hello world")
    }

    // MARK: - Sync

    @Test func syncUploadURLEndpoint() throws {
        let e = SyncUploadURLEndpoint(body: .init(key: "books/abc.epub", contentType: "application/epub+zip"))
        #expect(e.path == "/api/sync/upload-url")
        #expect(e.method == .POST)
        let json = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(json.contains("\"content_type\""))
        #expect(json.contains("\"key\""))
    }

    @Test func syncDownloadURLEndpoint() throws {
        let e = SyncDownloadURLEndpoint(body: .init(key: "books/abc.epub"))
        #expect(e.path == "/api/sync/download-url")
        #expect(e.method == .POST)
        let json = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(json.contains("\"key\""))
    }

    @Test func presignedURLResponseDecodes() throws {
        let json = #"{"url":"https://r2/x","expires_at":1700000000}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let r = try dec.decode(PresignedURLResponse.self, from: Data(json.utf8))
        #expect(r.url == "https://r2/x")
        #expect(r.expiresAt.timeIntervalSince1970 == 1_700_000_000)
    }

    // MARK: - Billing

    @Test func billingPortalShape() throws {
        let e = BillingPortalEndpoint()
        #expect(e.path == "/api/billing/portal")
        #expect(e.method == .POST)
        let json = #"{"url":"https://billing.stripe.com/p/x"}"#
        let r = try JSONDecoder().decode(BillingPortalEndpoint.PortalResponse.self, from: Data(json.utf8))
        #expect(r.url == "https://billing.stripe.com/p/x")
    }
}

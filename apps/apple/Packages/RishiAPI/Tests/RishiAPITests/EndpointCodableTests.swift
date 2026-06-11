import Foundation
import Testing
@testable import RishiAPI

@Suite("Endpoint Codable + path correctness")
struct EndpointCodableTests {

    // MARK: - Auth

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

    /// Better Auth's `GET /api/auth/get-session` returns literal JSON `null` when
    /// no session is present. The endpoint's typed `Response` must decode that
    /// cleanly as `nil` rather than throwing `valueNotFound`. Regression guard
    /// for Phase 15 plan 05.
    @Test func getSessionResponseDecodesNullAsNil() throws {
        let json = "null"
        let r = try JSONDecoder().decode(GetSessionEndpoint.Response.self, from: Data(json.utf8))
        #expect(r == nil)
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
    // BillingPortalEndpoint removed in Phase 13 — Stripe portal handoff
    // replaced by native StoreKit `AppStore.showManageSubscriptions(in:)`
    // (see RishiBilling/StoreKit/ManageSubscriptionPresenter.swift).

    // MARK: - Users

    @Test func usersSearchEndpoint() throws {
        let e = UsersSearchEndpoint(body: .init(query: "alice"))
        #expect(e.path == "/v1/users/search")
        #expect(e.method == .POST)
        let bodyJSON = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(bodyJSON.contains("\"query\""))
        #expect(bodyJSON.contains("\"alice\""))
        let json = #"{"users":[{"id":"u","email":"a@b","display_name":"A","avatar_url":"https://x"}]}"#
        let r = try JSONDecoder().decode(UsersSearchEndpoint.SearchResponse.self, from: Data(json.utf8))
        #expect(r.users.count == 1)
        #expect(r.users[0].displayName == "A")
        #expect(r.users[0].avatarURL == "https://x")
    }

    // MARK: - Sessions

    @Test func createSessionEndpoint() throws {
        let e = CreateSessionEndpoint(body: .init(bookId: "b"))
        #expect(e.path == "/v1/sessions")
        #expect(e.method == .POST)
        let bodyJSON = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(bodyJSON.contains("\"book_id\""))
        let json = #"""
        {"session_id":"s1","reconnect_token":"r1","ws_url":"wss://x","expires_at":1700000000}
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let r = try dec.decode(CreateSessionEndpoint.CreateResponse.self, from: Data(json.utf8))
        #expect(r.sessionId == "s1")
        #expect(r.reconnectToken == "r1")
        #expect(r.wsUrl == "wss://x")
    }

    @Test func redeemSessionEndpointInterpolatesId() throws {
        let e = RedeemSessionEndpoint(sessionId: "sess-1", body: .init(token: "tok"))
        #expect(e.path == "/v1/sessions/sess-1/redeem")
        #expect(e.method == .POST)
        let json = #"{"success":true,"host_user_id":"host-7"}"#
        let r = try JSONDecoder().decode(RedeemSessionEndpoint.RedeemResponse.self, from: Data(json.utf8))
        #expect(r.success == true)
        #expect(r.hostUserId == "host-7")
    }

    // MARK: - Desktop

    @Test func desktopStartEndpoint() throws {
        let e = DesktopStartEndpoint(body: .init(codeChallenge: "c", mode: "magic-link", email: "x@y"))
        #expect(e.path == "/desktop/start")
        #expect(e.method == .POST)
        let bodyJSON = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(bodyJSON.contains("\"code_challenge\""))
        let json = #"{"flow_id":"f1","web_url":"https://accounts/x"}"#
        let r = try JSONDecoder().decode(DesktopStartEndpoint.StartResponse.self, from: Data(json.utf8))
        #expect(r.flowId == "f1")
        #expect(r.webURL == "https://accounts/x")
    }

    @Test func desktopPollEndpoint() throws {
        let e = DesktopPollEndpoint(body: .init(flowId: "f", codeVerifier: "v"))
        #expect(e.path == "/desktop/poll")
        let bodyJSON = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(bodyJSON.contains("\"flow_id\""))
        #expect(bodyJSON.contains("\"code_verifier\""))
        let json = #"{"session_token":"tok","status":"complete"}"#
        let r = try JSONDecoder().decode(DesktopPollEndpoint.PollResponse.self, from: Data(json.utf8))
        #expect(r.sessionToken == "tok")
        #expect(r.status == "complete")
    }

    @Test func desktopCancelEndpoint() throws {
        let e = DesktopCancelEndpoint(body: .init(flowId: "f"))
        #expect(e.path == "/desktop/cancel")
        let bodyJSON = String(data: try JSONEncoder().encode(e.body), encoding: .utf8) ?? ""
        #expect(bodyJSON.contains("\"flow_id\""))
    }
}

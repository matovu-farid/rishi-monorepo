import Foundation
import Testing
@testable import rishi

@Suite("Google auth endpoint")
struct GoogleAuthAPIContractTests {
    @Test("sends the Google ID token to the Apple-compatible auth route")
    func requestContract() throws {
        let endpoint = GoogleAuthEndpoint(body: .init(identityToken: "google-id-token"))
        let json = try JSONEncoder().encode(endpoint.body)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: String])

        #expect(endpoint.method == .POST)
        #expect(endpoint.path == "/auth/google")
        #expect(object == ["identityToken": "google-id-token"])
    }
}

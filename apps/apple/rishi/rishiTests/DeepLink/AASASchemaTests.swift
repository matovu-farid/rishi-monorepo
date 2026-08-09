

import Testing
import Foundation
@testable import rishi

@MainActor
@Suite("AASA schema parity with worker ticket")
struct AASASchemaTests {


    static let canonicalJSON = """
    {
      "applinks": {
        "details": [
          {
            "appIDs": ["9VL7VRY6QZ.org.fidexa.rishi"],
            "components": [
              { "/": "/auth/callback*", "comment": "SIWA + Google OAuth callback after web sign-in" },
              { "/": "/sharing/join*",  "comment": "Sharing redeem deep link" },
              { "/": "/app/*",          "comment": "Generic in-app routing" }
            ]
          }
        ]
      },
      "webcredentials": { "apps": ["9VL7VRY6QZ.org.fidexa.rishi"] }
    }
    """

    @Test("Decodes the worker-ticket canonical JSON")
    func decodesCanonical() throws {
        let data = Self.canonicalJSON.data(using: .utf8)!
        let aasa = try JSONDecoder().decode(AASA.self, from: data)
        #expect(aasa.applinks.details.count == 1)
        #expect(aasa.applinks.details[0].appIDs == ["9VL7VRY6QZ.org.fidexa.rishi"])
        #expect(aasa.applinks.details[0].components.count == 3)
        #expect(aasa.applinks.details[0].components[0].path == "/auth/callback*")
        #expect(aasa.applinks.details[0].components[1].path == "/sharing/join*")
        #expect(aasa.applinks.details[0].components[2].path == "/app/*")
        #expect(aasa.webcredentials?.apps == ["9VL7VRY6QZ.org.fidexa.rishi"])
    }

    @Test("Round-trip encode/decode is stable")
    func roundTrip() throws {
        let data = Self.canonicalJSON.data(using: .utf8)!
        let first = try JSONDecoder().decode(AASA.self, from: data)
        let reencoded = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode(AASA.self, from: reencoded)
        #expect(first == second)
    }

    @Test("Component comments survive round-trip")
    func commentRoundTrip() throws {
        let data = Self.canonicalJSON.data(using: .utf8)!
        let first = try JSONDecoder().decode(AASA.self, from: data)
        let reencoded = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode(AASA.self, from: reencoded)
        #expect(second.applinks.details[0].components[0].comment
                == "SIWA + Google OAuth callback after web sign-in")
    }

    @Test("Missing webcredentials still decodes")
    func missingWebCredentials() throws {
        let json = """
        {"applinks":{"details":[{"appIDs":["X.org.fidexa.rishi"],"components":[{"/":"/x"}]}]}}
        """
        let aasa = try JSONDecoder().decode(AASA.self, from: json.data(using: .utf8)!)
        #expect(aasa.webcredentials == nil)
    }

    @Test("Component without comment decodes")
    func componentWithoutComment() throws {
        let json = """
        {"applinks":{"details":[{"appIDs":["X"],"components":[{"/":"/x"}]}]}}
        """
        let aasa = try JSONDecoder().decode(AASA.self, from: json.data(using: .utf8)!)
        #expect(aasa.applinks.details[0].components[0].comment == nil)
    }

    @Test("Web AASA advertises the same Apple app and share paths")
    func webFileMatchesContract() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DeepLink
            .deletingLastPathComponent() // rishiTests
            .deletingLastPathComponent() // rishi
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // apps
        let webFile = repoRoot
            .appendingPathComponent("apps/web/public/.well-known/apple-app-site-association")
        let webAASA = try JSONDecoder().decode(AASA.self, from: Data(contentsOf: webFile))
        let canonical = try JSONDecoder().decode(AASA.self, from: Data(Self.canonicalJSON.utf8))
        #expect(webAASA.applinks.details[0].appIDs == canonical.applinks.details[0].appIDs)
        #expect(webAASA.applinks.details[0].components.map(\.path) == canonical.applinks.details[0].components.map(\.path))
        #expect(webAASA.webcredentials?.apps == canonical.webcredentials?.apps)
    }
}

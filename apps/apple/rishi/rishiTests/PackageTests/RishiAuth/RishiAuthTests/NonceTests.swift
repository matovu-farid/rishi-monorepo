@testable import rishi
import Testing
import Foundation
import CryptoKit


/// Nonce contract per PITFALLS Pitfall 1 (RESEARCH.md):
/// - `generate()` returns a `(raw, sha256Hex)` tuple where `sha256Hex` is the
///   SHA-256 hex digest of the UTF-8 bytes of `raw`.
/// - The hex digest is what we send to BOTH Apple (as
///   `ASAuthorizationAppleIDRequest.nonce`) AND Better Auth (as
///   `idToken.nonce`). Apple stores the supplied string verbatim in the JWT
///   `nonce` claim; Better Auth compares `jwtClaims.nonce !== nonce`
///   (apple.mjs:58) — meaning the value we POST as `idToken.nonce` must be
///   string-identical to what the JWT carries.
@Suite("NonceTests")
struct NonceTests {

    @Test func generateProducesDeterministicHash() {
        let (raw, hex) = Nonce.generate()
        let expected = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(hex == expected)
    }

    @Test func consecutiveCallsAreRandom() {
        let a = Nonce.generate()
        let b = Nonce.generate()
        #expect(a.raw != b.raw)
        #expect(a.sha256Hex != b.sha256Hex)
    }

    @Test func sha256IsSixtyFourHexChars() {
        let (_, hex) = Nonce.generate()
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })
    }
}

import Foundation
import CryptoKit

/// CSRF-binding nonce for the Sign-in-with-Apple flow.
///
/// Recipe per PITFALLS Pitfall 1 (Phase 15 RESEARCH.md):
/// 1. Generate a fresh random `raw` string.
/// 2. Compute `sha256Hex = SHA256(raw.utf8).hexString`.
/// 3. Hand `sha256Hex` to BOTH:
///    - `ASAuthorizationAppleIDRequest.nonce` — Apple stores the string
///      verbatim in the JWT `nonce` claim (it does NOT re-hash a hex string).
///    - `idToken.nonce` in the Better Auth `/api/auth/sign-in/social` body.
///      Better Auth's check at `apple.mjs:58` is string-equality between
///      `jwtClaims.nonce` and the supplied `nonce`. Both sides see the SAME
///      hex digest.
///
/// The raw value is kept for symmetry / debugging but does not need to be sent
/// anywhere: only the SHA-256 hex digest travels on the wire.
enum Nonce {
    /// Returns a fresh `(raw, sha256Hex)` pair. Each call is independently
    /// random.
    static func generate() -> (raw: String, sha256Hex: String) {
        let raw = (0..<16)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
            .joined()
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (raw, hex)
    }
}

import Foundation
import CryptoKit
import StoreKit
import RishiCore

/// Derives and supplies the `appAccountToken` StoreKit purchase option that
/// links an Apple transaction to the authenticated Rishi user, per the
/// 2026-07-17 pricing/trial-launch design doc's "Authoritative entitlement
/// model": *"When an authenticated user initiates an Apple purchase, Rishi
/// passes that user's stable `appAccountToken` UUID in StoreKit's purchase
/// options... The Worker accepts an entitlement sync only when... the
/// transaction's `appAccountToken` matches the authenticated Rishi user."*
public enum AppAccountToken {

    /// Fixed RFC 4122 v5 namespace. MUST byte-for-byte match the Worker's
    /// `APP_ACCOUNT_TOKEN_NAMESPACE` constant in
    /// `workers/worker/src/billing/entitlement-sync.ts` — changing this
    /// silently breaks every previously derived token's match against the
    /// Worker. Generated once (2026-07-17); never regenerate.
    private static let namespace = "fbf6524d-646b-4317-b479-476821e250f6"

    /// Deterministic UUID v5 = SHA-1(namespaceBytes ++ utf8Bytes(userId)),
    /// with the version nibble (byte 6) and RFC 4122 variant bits (byte 8)
    /// patched exactly as the Worker's `deriveAppAccountToken` does. Same
    /// `userId` always yields the same `UUID`; the Worker computes the
    /// identical value independently, so no round trip or new storage is
    /// needed to keep the two in sync.
    ///
    /// `userId` MUST be the Worker's Rishi `user.id` string — Better Auth's
    /// 32-character alphanumeric `generateId()` output, exposed to this app
    /// as ``Session/userId`` (persisted by ``KeychainSessionStore``). Do
    /// NOT pass `RishiCore`'s local `UserID`/`DerivedUserID` — those are
    /// unrelated, purely-local UUID-shaped storage keys.
    public static func derive(userId: String) -> UUID {
        let namespaceBytes = uuidStringToBytes(namespace)
        let nameBytes = Array(userId.utf8)
        let digest = Insecure.SHA1.hash(data: Data(namespaceBytes + nameBytes))
        var hash = Array(digest.prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50 // version 5
        hash[8] = (hash[8] & 0x3f) | 0x80 // RFC 4122 variant
        return uuid(fromBytes: hash)
    }

    /// StoreKit purchase options for the currently signed-in user, ready to
    /// pass to `product.purchase(options:)`, the `\.purchase` `PurchaseAction`,
    /// or `SubscriptionStoreView`'s `.inAppPurchaseOptions(_:)`. Returns an
    /// empty set (StoreKit's own default — no `appAccountToken` attached)
    /// if no session is currently persisted. The paywall is only reachable
    /// while signed in, so this is a defensive fallback, not an expected
    /// path; a purchase without a token simply cannot be matched to a Rishi
    /// account server-side, which the Worker's entitlement-sync guard
    /// already rejects safely (`app_account_token_mismatch`).
    public static func currentPurchaseOptions(
        sessionStore: KeychainSessionStore = KeychainSessionStore()
    ) async -> Set<Product.PurchaseOption> {
        guard let session = try? await sessionStore.load() else { return [] }
        return [.appAccountToken(derive(userId: session.userId))]
    }

    // MARK: - Byte plumbing (mirrors the Worker's uuidStringToBytes 1:1)

    private static func uuidStringToBytes(_ uuidString: String) -> [UInt8] {
        let hex = uuidString.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// Swift's native tuple-based `UUID(uuid:)` initializer replaces the
    /// Worker's separate `bytesToUuidString` string-formatting step — same
    /// 16 bytes in, same canonical UUID out, no string-formatting bugs
    /// possible on this side.
    private static func uuid(fromBytes bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

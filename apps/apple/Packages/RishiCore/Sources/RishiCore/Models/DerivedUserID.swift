import Foundation

/// Derives a stable in-memory `UUID` (`RishiCore.UserID`) from an arbitrary
/// Better Auth `user.id` String (for Apple sign-in, the `sub` claim).
///
/// Plan 15-02: `Session.userId` is a `String`, but the rest of the app graph
/// (BookStore, PositionStore, LibraryViewModel, SyncEngine) keys every owner FK
/// off a `UUID`. This type bridges the two: the same input String always yields
/// the same UUID, so the in-memory `User.id` is stable across sign-ins.
///
/// **Migration-sensitive.** The namespace bytes and the hashing/bit-packing
/// algorithm below are load-bearing: changing any of them would shuffle every
/// Apple user's derived UUID and re-key their on-device data. The derivation
/// is pinned by ``DerivedUserIDTests`` expected-output vectors and must NOT be
/// altered without an explicit migration plan. This is a wholly separate
/// reason-to-change from the auth orchestration in ``RishiAuthService``, which
/// is why the algorithm lives here as its own value type.
///
/// Pure and `Sendable`, so it is callable from any isolation context.
public struct DerivedUserID: Sendable, Equatable {

    /// The derived stable UUID.
    public let uuid: UUID

    /// Derives a stable UUID from an arbitrary identifier String.
    ///
    /// If `id` already parses as a UUID (legacy Phase-3 keychain blobs
    /// where the userId was a real UUID string), return that UUID verbatim
    /// so existing on-device sessions keep the same in-memory User.id
    /// across the migration.
    ///
    /// Otherwise compute a name-based UUID by hashing the input with a
    /// fixed namespace and packing the first 16 bytes into a UUID with
    /// RFC 4122 version 5 / variant bits set. Same input always yields the
    /// same UUID.
    public static func from(_ id: String) -> UUID {
        if let direct = UUID(uuidString: id) {
            return direct
        }
        // Fixed namespace bytes for Rishi-Apple-derived user IDs. Random
        // 16-byte literal chosen once; do not change without a migration
        // plan (would shuffle every Apple user's derived UUID).
        var bytes: [UInt8] = [
            0x52, 0x49, 0x53, 0x48, 0x49, 0x41, 0x55, 0x54,
            0x48, 0x55, 0x53, 0x45, 0x52, 0x49, 0x44, 0x73,
        ]
        for byte in id.utf8 {
            // FNV-1a-ish 8-bit mix into a 16-byte rolling state.
            let idx = Int(byte) % 16
            bytes[idx] = bytes[idx] &+ byte
            bytes[idx] ^= UInt8((Int(bytes[idx]) &* 31 + Int(byte)) & 0xFF)
        }
        // Stir again with the full string length so short inputs don't
        // collapse onto each other.
        let len = UInt32(id.utf8.count)
        bytes[0] ^= UInt8(len & 0xFF)
        bytes[1] ^= UInt8((len >> 8) & 0xFF)
        bytes[2] ^= UInt8((len >> 16) & 0xFF)
        bytes[3] ^= UInt8((len >> 24) & 0xFF)
        // Set version (5) and variant (RFC 4122) per UUIDv5 layout.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Convenience initializer that stores the derived UUID for ``id``.
    public init(_ id: String) {
        self.uuid = Self.from(id)
    }
}

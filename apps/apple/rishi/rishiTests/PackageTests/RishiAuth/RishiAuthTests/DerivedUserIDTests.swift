@testable import rishi
import Foundation
import Testing


/// Pins the migration-sensitive ``DerivedUserID`` derivation algorithm.
///
/// The expected UUID vectors below are byte-for-byte load-bearing: they are
/// the exact outputs the algorithm produced when it lived inline in
/// `RishiAuthService.deriveUserUUID`. If any of these change, every Apple
/// user's in-memory `User.id` would shift and re-key their on-device data —
/// so a failure here means a behavior-changing edit slipped in, NOT a flaky
/// test. Do not "fix" by updating the vectors; revert the algorithm change.
@Suite("DerivedUserID — stable, migration-sensitive UUID derivation")
struct DerivedUserIDTests {

    /// Apple-`sub`-shaped fixture (matches RishiAuthServiceTests.appleSubFixture).
    @Test func derivesPinnedUUIDForAppleSubFixture() {
        #expect(
            DerivedUserID.from("001234.abcdef0123456789.1234")
                == UUID(uuidString: "DCCD0ACB-84E9-5687-B8E5-534552494E73")
        )
    }

    /// Single-character input — exercises the length-stir branch.
    @Test func derivesPinnedUUIDForSingleChar() {
        #expect(
            DerivedUserID.from("a")
                == UUID(uuidString: "535D5348-4941-5554-8855-534552494473")
        )
    }

    /// Empty input — derives from the namespace bytes alone.
    @Test func derivesPinnedUUIDForEmptyString() {
        #expect(
            DerivedUserID.from("")
                == UUID(uuidString: "52495348-4941-5554-8855-534552494473")
        )
    }

    /// Legacy Phase-3 keychain blobs stored a real UUID string in `userId`;
    /// those must round-trip verbatim so on-device sessions keep their id.
    @Test func returnsUUIDVerbatimWhenInputAlreadyParsesAsUUID() {
        let raw = "550E8400-E29B-41D4-A716-446655440000"
        #expect(DerivedUserID.from(raw) == UUID(uuidString: raw))
    }

    /// Determinism: same input always yields the same UUID.
    @Test func derivationIsDeterministic() {
        let id = "001234.abcdef0123456789.1234"
        #expect(DerivedUserID.from(id) == DerivedUserID.from(id))
    }

    /// Distinct inputs that differ only in length must not collapse (the
    /// length-stir guards against this).
    @Test func distinctInputsProduceDistinctUUIDs() {
        #expect(DerivedUserID.from("a") != DerivedUserID.from("aa"))
    }

    /// The convenience initializer stores the same UUID as the static API.
    @Test func initStoresSameUUIDAsStaticAPI() {
        let id = "001234.abcdef0123456789.1234"
        #expect(DerivedUserID(id).uuid == DerivedUserID.from(id))
    }
}

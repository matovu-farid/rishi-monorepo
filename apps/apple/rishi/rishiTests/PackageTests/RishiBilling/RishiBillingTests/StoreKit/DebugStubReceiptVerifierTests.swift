@testable import rishi
#if DEBUG
import Foundation
import Testing


/// Contract tests for ``DebugStubReceiptVerifier`` — the `#if DEBUG`-only
/// stub that lets simulator builds complete a fake purchase end-to-end
/// without a live worker. Wired in `AppDependencies` via
/// `UserDefaults.standard.bool(forKey: "RishiUseStubReceiptVerifier")`.
///
/// Suite mirrors the Phase 14 plan 14-07 acceptance criteria:
///  1. `verified == true`
///  2. `premiumUntil` is ~30 days out (29 < x < 31 days, allowing for
///     execution timing slop)
///  3. `reason == nil`
///  4. Compile-time conformance to `ReceiptVerifier`
///  5. Output invariant under any caller input
@Suite("DebugStubReceiptVerifier")
struct DebugStubReceiptVerifierTests {

    @Test("returns verified == true")
    func returnsVerified() async throws {
        let stub = DebugStubReceiptVerifier()
        let response = try await stub.verify(jws: "any", productId: "any", transactionId: 1)
        #expect(response.verified == true)
    }

    @Test("premiumUntil is ~30 days from now")
    func premiumUntilWindow() async throws {
        let stub = DebugStubReceiptVerifier()
        let before = Date()
        let response = try await stub.verify(jws: "j", productId: "p", transactionId: 1)
        let after = Date()
        let until = try #require(response.premiumUntil)
        let earliestExpected = before.addingTimeInterval(29 * 24 * 60 * 60)
        let latestExpected = after.addingTimeInterval(31 * 24 * 60 * 60)
        #expect(until > earliestExpected)
        #expect(until < latestExpected)
    }

    @Test("reason is nil")
    func reasonIsNil() async throws {
        let stub = DebugStubReceiptVerifier()
        let response = try await stub.verify(jws: "j", productId: "p", transactionId: 1)
        #expect(response.reason == nil)
    }

    @Test("conforms to ReceiptVerifier (compile-time)")
    func conformsToProtocol() async throws {
        let stub: any ReceiptVerifier = DebugStubReceiptVerifier()
        let response = try await stub.verify(jws: "j", productId: "p", transactionId: 1)
        #expect(response.verified == true)
    }

    @Test("invariant under input variation")
    func invariantUnderInputs() async throws {
        let stub = DebugStubReceiptVerifier()
        let a = try await stub.verify(jws: "a", productId: "p1", transactionId: 1)
        let b = try await stub.verify(jws: "b", productId: "p2", transactionId: 999_999_999_999_999)
        #expect(a.verified == true)
        #expect(b.verified == true)
    }
}
#endif

#if DEBUG
import Foundation

/// DEBUG-only stub verifier — bypasses the worker for offline / pre-deploy
/// testing of the StoreKit IAP flow in the simulator.
///
/// Activation: set `UserDefaults.standard.bool(forKey: "RishiUseStubReceiptVerifier") == true`
/// (e.g. `defaults write org.fidexa.rishi RishiUseStubReceiptVerifier -bool YES`)
/// alongside the existing StoreKit IAP feature flag
/// (`defaults write org.fidexa.rishi StoreKitIAPFlag -bool YES`).
///
/// Wiring: `AppDependencies` (rishi/rishi) chooses this vs
/// ``WorkerReceiptVerifier`` at construction time based on the UserDefaults
/// gate, behind its own `#if DEBUG` branch. Release builds physically cannot
/// reference this type.
///
/// Compile-strip guarantee (mirrors Phase 3 ``DevBypassConfig`` pattern
/// recorded in STATE.md): the ENTIRE file is wrapped in `#if DEBUG`. Release
/// builds emit a zero-symbol `.o`, so a future linker-symbol-grep CI guard
/// (`nm .build/release/RishiBilling.o | grep DebugStub` → empty) can be
/// added without touching this source.
///
/// Return contract:
///  - `verified == true`
///  - `premiumUntil == now + 30 days`
///  - `reason == nil`
///
/// The 30-day window is long enough for a TestFlight build cycle but short
/// enough that a stale stub doesn't accidentally grant "forever-Pro" to a
/// reviewer who picked up an old simulator build with the flag still on.
///
/// Output is invariant under any (`jws`, `productId`, `transactionId`) tuple
/// — the stub does not consult the inputs.
public actor DebugStubReceiptVerifier: ReceiptVerifier {

    public init() {}

    public func verify(jws: String, productId: String, transactionId: UInt64)
        async throws -> VerifyReceiptResponse {
        let premiumUntil = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return VerifyReceiptResponse(
            verified: true,
            premiumUntil: premiumUntil,
            reason: nil
        )
    }
}
#endif

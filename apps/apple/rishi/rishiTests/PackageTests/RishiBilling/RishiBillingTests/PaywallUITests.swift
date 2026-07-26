@testable import rishi
import Testing
import Foundation
import SwiftUI


/// Plan 13-05 — Paywall UI smoke tests.
///
/// The Wave-3 paywall rewrite gates its body on `StoreKitIAPFlag`:
///   - flag ON  → live, hand-rolled SwiftUI paywall consuming a VM
///   - flag OFF → text-only fallback (zero regression for release builds
///     where StoreKitIAPFlag is hardcoded false)
///
/// These tests are compile-time / construction smoke tests — they prove
/// the view type-checks against both flag states. They do NOT attempt to
/// render against a SwiftUI host, which is not supported under `swift test`.
@MainActor
@Suite("Paywall UI flag-gated smoke")
struct PaywallUITests {

    private func makeVM() -> PaywallViewModel {
        let productService = StoreKitProductService()
        let purchase = PaywallViewModelTests.StubPurchaseProvider(mode: .cancelled)
        let restore = PaywallViewModelTests.StubRestoreProvider(mode: .nothingToRestore)
        let presenter = ManageSubscriptionPresenter(
            invoker: PaywallViewModelTests.StubManageInvoker()
        )
        return PaywallViewModel(
            productService: productService,
            purchaseService: purchase,
            restoreService: restore,
            managePresenter: presenter
        )
    }

    @Test("PaywallView constructs with the live VM (flag ON path compiles)")
    func liveBody_constructs_whenFlagOn() {
        #if DEBUG
        let previous = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(true)
        defer { StoreKitIAPFlag.setEnabled(previous) }
        #endif
        let view = PaywallView(viewModel: makeVM())
        _ = view
    }

    @Test("PaywallView constructs in fallback body when flag is OFF")
    func fallbackBody_constructs_whenFlagOff() {
        #if DEBUG
        let previous = StoreKitIAPFlag.isEnabled
        StoreKitIAPFlag.setEnabled(false)
        defer { StoreKitIAPFlag.setEnabled(previous) }
        #endif
        let view = PaywallView(viewModel: makeVM())
        _ = view
    }
}

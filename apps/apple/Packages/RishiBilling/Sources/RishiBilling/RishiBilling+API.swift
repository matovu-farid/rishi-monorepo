// RishiBilling — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiBilling exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiBilling owns StoreKit 2 integration: product loading,
// purchase, restore, receipt verification (via the Worker), and
// the entitlement-state machine that downstream features read.
// Plus the paywall UI and the .premiumGate view modifier.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 2 unused exports).

// MARK: - Views
//
// PaywallView                 — `UI/PaywallView.swift`. The full paywall screen.
// PaywallViewModel            — `UI/PaywallViewModel.swift`. State + actions for PaywallView.
// ManageSubscriptionRow       — `UI/ManageSubscriptionRow.swift`. Settings row to open
//                                "Manage Subscription" inside the App Store sheet.
// PremiumGateModifier         — `UI/PremiumGateModifier.swift`. View modifier that overlays
//                                the paywall when a premium feature is tapped without an
//                                entitlement. Use via the `.premiumGate(...)` extension.
// paywallSubscribeAction      — `UI/PaywallSubscribeAction.swift`. Free function that drives
//                                the Subscribe button: purchase -> verify -> reconcile.

// MARK: - Services
//
// EntitlementService          — `Service/EntitlementService.swift`. Actor. The single source
//                                of truth for "does the user have Pro right now?".
// PurchaseService             — `StoreKit/PurchaseService.swift`. Actor. Drives a single
//                                StoreKit Product.purchase() call.
// RestoreService              — `StoreKit/RestoreService.swift`. Actor. AppStore.sync() +
//                                receipt re-verification.
// StoreKitProductService      — `StoreKit/StoreKitProductService.swift`. Actor. Loads
//                                Product objects from StoreKit and exposes a ProductCatalog.
// TransactionListener         — `StoreKit/TransactionListener.swift`. Actor. Listens for
//                                Transaction.updates across the app lifetime.

// MARK: - Receipt verification
//
// ReceiptVerifier             — `StoreKit/ReceiptVerifier.swift`. Protocol seam.
// WorkerReceiptVerifier       — `StoreKit/WorkerReceiptVerifier.swift`. Production verifier
//                                that calls the Worker's /verify-receipt endpoint.
// DebugStubReceiptVerifier    — `StoreKit/DebugStubReceiptVerifier.swift`. Always-grants
//                                verifier for debug builds and CI.
// VerifyReceiptResponse       — `StoreKit/ReceiptVerifier.swift`. Server response value.
// VerifyReceiptError          — `StoreKit/ReceiptVerifier.swift`. Verifier error enum.
// ProductFetching             — `StoreKit/ReceiptVerifier.swift`. Protocol seam for product loading.

// MARK: - Entitlement reconciliation
//
// EntitlementReconciler       — `Entitlements/EntitlementReconciler.swift`. Maps verified
//                                receipts + StoreKit transactions into an EntitlementLevel.
// ReaderAppEntitlementFlag    — `Entitlements/ReaderAppEntitlementFlag.swift`. Observable
//                                flag the UI binds to ("user is Pro").
// StoreKitIAPFlag             — `Entitlements/EntitlementReconciler.swift`. Namespace
//                                holding the kill-switch flag for StoreKit IAP.

// MARK: - Manage subscription
//
// ManageSubscriptionPresenter — `StoreKit/ManageSubscriptionPresenter.swift`. Drives the
//                                AppStore Manage-Subscriptions sheet.
// ManageSubscriptionInvoker   — `StoreKit/ManageSubscriptionPresenter.swift`. Protocol
//                                seam; production calls AppStore.showManageSubscriptions.
// DefaultManageSubscriptionInvoker
//                             — `StoreKit/ManageSubscriptionPresenter.swift`. The default.
// ManageSubscriptionOutcome   — `StoreKit/ManageSubscriptionPresenter.swift`. .closed /
//                                .cancelledSubscription / .didNothing.
// ManageSubscriptionError     — `StoreKit/ManageSubscriptionPresenter.swift`. Error enum.

// MARK: - Models / Types
//
// EntitlementLevel            — `Models/EntitlementLevel.swift`. .free / .pro.
// ProductSnapshot             — `StoreKit/ProductSnapshot.swift`. Sendable snapshot of a
//                                StoreKit Product (id, display price, period).
// ProductCatalog              — `StoreKit/ProductSnapshot.swift`. The loaded set of snapshots.
// PurchaseOutcome             — `StoreKit/PurchaseService.swift`. .success / .cancelled /
//                                .pending.
// PurchaseError               — `StoreKit/PurchaseService.swift`. Purchase error enum.
// PurchaseProtocol            — `StoreKit/PurchaseService.swift`. Protocol seam.
// RestoreOutcome              — `StoreKit/RestoreService.swift`. .restored / .nothingToRestore.
// RestoreError                — `StoreKit/RestoreService.swift`. Restore error enum.
// RestoreProtocol             — `StoreKit/RestoreService.swift`. Protocol seam.
// StoreKitProductLoadError    — `StoreKit/StoreKitProductService.swift`. Load error enum.
// PurchaseUpdateForwarder     — `StoreKit/TransactionListener.swift`. Lets the listener
//                                forward updates into PurchaseService without a hard ref.

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
// EntitlementSyncing            — `StoreKit/EntitlementSyncClient.swift`. Protocol seam.
// EntitlementSyncClient         — `StoreKit/EntitlementSyncClient.swift`. Actor. Production
//                                  sync client wrapping WorkerClient, POSTs to
//                                  /api/billing/entitlement-sync. Used by PurchaseService;
//                                  Store/CustomerEntitlements/RestoreService instead call
//                                  the internal syncEntitlement(jws:) helper (awaited;
//                                  finish only after success). EntitlementSyncHooks.onSynced
//                                  is wired by the app to refreshSnapshot().

// MARK: - Entitlement reconciliation
//
// EntitlementReconciler       — `Entitlements/EntitlementReconciler.swift`. Maps verified
//                                receipts + StoreKit transactions into an EntitlementLevel.
// ReaderAppEntitlementFlag    — `Entitlements/ReaderAppEntitlementFlag.swift`. Observable
//                                flag the UI binds to ("user is Pro").
// StoreKitIAPFlag             — `Entitlements/EntitlementReconciler.swift`. Namespace
//                                holding the kill-switch flag for StoreKit IAP.
// EntitlementSnapshotStore    — `Entitlements/EntitlementSnapshotStore.swift`. @MainActor
//                                @Observable bridge from EntitlementService.currentSnapshot;
//                                RootView and downstream views read `.snapshot`/`.clientStates`
//                                via @Environment.
// EntitlementClientState      — `Entitlements/EntitlementClientState.swift`. Typed flags: trial
//                                exhaustion, paid narration/Voice-Chat exhaustion (derivable from
//                                EntitlementSnapshot), plus Voice-Chat-warning/terminal-cap/
//                                provider-setup-failure seams a later plan populates.

// MARK: - AI-feature exhaustion gate
//
// AIFeature                   — `Entitlements/AIFeatureGate.swift`. .narration
//                                / .voiceChat — the two gate-able AI entry points.
// AIFeatureBlockReason        — `Entitlements/AIFeatureGate.swift`. Why an AI
//                                feature tap was intercepted. Identifiable.
// EntitlementSnapshot.blockReason(for:)
//                              — `Entitlements/AIFeatureGate.swift`. Pure access
//                                check on plan 12's EntitlementSnapshot (RishiCore).
//                                Call before starting narration or a Voice Chat session.
// RemainingAllowanceView      — `UI/RemainingAllowanceView.swift`. Renders the
//                                account's remaining allowance (credits for
//                                trial, human-readable time for Reader/Voice).
//                                Never shows a raw credit number to a paid user.
// AIFeatureUpgradePrompt      — `UI/AIFeatureUpgradePrompt.swift`. Non-blocking
//                                sheet shown when an AI feature is intercepted.
//                                Present via `.sheet(item:)`; core reading is
//                                never blocked.

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
// RishiProductID              — `Models/RishiProductID.swift`. The six Apple product ids
//                                (2 legacy Pro + 4 Reader/Voice) — single source of truth
//                                for Store.fetchProductIDs() and EntitlementLevel.initialize.
// AppAccountToken              — `Entitlements/AppAccountToken.swift`. UUID v5 derivation
//                                (byte-identical to the Worker's) + currentPurchaseOptions() throws.
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

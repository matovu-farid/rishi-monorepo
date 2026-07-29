# Catalyst Subscription Experience Parity

## Goal

Make the macOS Catalyst subscription flow behave like the approved iOS flow while retaining Mac-specific StoreKit products and Apple-controlled subscription management.

## Scope

- Share the same paywall state model and copy on iOS and Catalyst.
- Show only the four current-platform products on Catalyst.
- Show the active-plan state and upgrade explanation for subscribers.
- Keep Apple’s native management sheet for cancellation and account-level subscription management.
- Keep Restore Purchases visible only when no active subscription is recognized.
- Dismiss the paywall after a verified purchase, refresh the entitlement, and show a short confirmation.
- Give Catalyst the wider layout needed for a Mac window without changing purchase semantics.

## Non-goals

- Do not merge iOS and Mac product IDs.
- Do not replace StoreKit’s native purchase or management UI.
- Do not change subscription groups, pricing, worker entitlement rules, or App Store Connect metadata.

## Behavior

1. An authenticated user sees a loading state until the current-platform catalog is complete.
2. An unsubscribed user sees the four Catalyst Reader/Voice plans, Restore Purchases, and Subscribe controls supplied by `SubscriptionStoreView`.
3. An active subscriber sees the current-plan indicator, Apple management/cancellation control, and only upgrade relationships. Restore Purchases is hidden.
4. A verified purchase processes the StoreKit transaction, refreshes the worker-backed entitlement, dismisses the sheet, and presents a confirmation message through the existing caller callback.
5. Failed, pending, cancelled, and unverified transactions leave the paywall open and do not claim entitlement.

## Implementation boundary

- `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift` owns shared presentation and purchase-completion behavior.
- `apps/apple/rishi/rishi/RootView.swift`, `Library/LibraryRootView.swift`, and `Settings/SettingsContent.swift` remain callers and receive the existing completion callback.
- `RishiProductID.currentPlatformPaywallProductIDs` remains the sole merchandising order for both platforms.
- Tests belong in `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/` and cover state presentation, platform catalog selection, and purchase completion behavior where the current architecture permits.

## Acceptance criteria

- Catalyst displays only `*.macos` products.
- Catalyst active subscribers see “Your current plan is active”, Apple management, and upgrade options, but no Restore Purchases button.
- iOS behavior remains unchanged.
- Verified purchase completion invokes the existing dismissal callback after entitlement refresh.
- The Catalyst Release build succeeds.

## Review status

Design approved by the user on 2026-07-28.

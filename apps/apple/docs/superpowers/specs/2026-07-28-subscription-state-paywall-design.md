# Subscription State Paywall Design

> **Status:** Approved by the user on 2026-07-28.

## Goal

Make the StoreKit paywall accurately distinguish an active subscription from upgrade choices, complete the purchase flow with dismissal and confirmation, and present restore failures in user-facing language.

## Decisions

1. Keep Apple’s `SubscriptionStoreView` as the purchase surface.
2. Use the app’s resolved entitlement snapshot for the cross-device/account-level active state, while using StoreKit’s current subscription relationships to determine which products are valid upgrades on the native picker.
3. When the account has an active paid plan, present an app-owned current-plan card with `Manage Subscription` and render the native StoreKit view with upgrade relationships only. This prevents Apple’s generic Subscribe CTA from being shown for the active plan while retaining Apple’s purchase UI for upgrades.
4. On a verified successful purchase, process the transaction first, refresh entitlements, dismiss the sheet, and deliver a one-time confirmation to the presenting screen. Pending and cancelled purchases do not dismiss or show success.
5. Preserve `Restore Purchases`. Map no-entitlement results to “No purchases were found to restore.” Map StoreKit sync and entitlement-sync failures to concise recovery guidance; never expose enum names or raw error descriptions in the UI.

## State flow

`EntitlementSnapshotStore.resolvedSnapshot` determines whether the user is already paid. `Store` continues to own product loading. `SubscriptionsView` receives the resolved paid state and a purchase-completed callback from its presenters. `RootView` and `SettingsContent` refresh the entitlement snapshot after dismissal and show the confirmation at the presentation owner, avoiding an alert behind a dismissed sheet.

## Out of scope

- Changing product IDs, prices, subscription groups, or worker entitlement rules.
- Replacing StoreKit with a custom purchase implementation.
- Removing Restore Purchases or hiding upgrade choices from active subscribers.

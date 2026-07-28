[Back to overview](../README.md)

# Billing (In-App Purchase + Paywall)

## What it does

Billing decides whether the current user is on the free tier or on Rishi Pro, sells the Pro subscription through Apple's in-app purchase system, and shows the paywall when a free user taps a Pro-only feature (Read Aloud, Chat with Book, Voice Chat, multi-device Sync). It uses Apple's native StoreKit 2 — the user buys directly inside the app, Apple handles the receipt, the worker confirms the receipt, and the app unlocks the feature.

## The user flow

- A free user taps a Pro feature. A modal paywall appears.
- The paywall shows two tiers (Monthly, Annual), the price pulled live from the App Store, plus the legally required auto-renewal disclosure.
- The user taps Subscribe. iOS shows Apple's native purchase sheet.
- On success, StoreKit emits an entitlement; the app sends the receipt to the worker, the worker stores it, and the user's status becomes Pro.
- The user can manage or cancel the subscription from the Settings screen, which opens Apple's in-app Manage Subscriptions sheet.

## Where it lives

| Role | File |
|------|------|
| Paywall screen | `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift` |
| Product catalog + StoreKit state | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift` |
| Purchase + restore services | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/PurchaseService.swift`, `RestoreService.swift` |
| Transaction listener | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/TransactionListener.swift` |
| Entitlement sync | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/EntitlementSyncClient.swift` |
| Manage Subscriptions launcher | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/ManageSubscriptionPresenter.swift` |
| Reconciler (device + server signal) | `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Entitlements/EntitlementReconciler.swift` |

## What it depends on

- `RishiCore` — `EntitlementLevel` and error types.
- `RishiAPI` — `VerifyReceiptEndpoint` and `GetSessionEndpoint` for the server side of the receipt check.
- `RishiAuth` — keychain-stored bearer token so the worker knows who is buying.
- `RishiUIKit` — design tokens for the paywall.
- `RishiLogging` — structured purchase / failure events.

## Why it's built this way

- Apple builds use native StoreKit 2 in-app purchase. The web and Electron billing implementations are separate products and are not part of the Apple purchase flow.
- `EntitlementReconciler` unions two signals: what `StoreKit.Transaction.currentEntitlements` reports on the device, and what `/api/auth/get-session` reports from the worker. The most permissive answer wins. This keeps the user unlocked when offline right after a purchase (device knows, server hasn't caught up) and when they switch devices (server knows, the new device hasn't called StoreKit yet).
- All paywall copy is reviewed against App Review Guideline 3.1.1 (no external steering) and 3.1.2 (auto-renewal disclosure must appear verbatim near the Subscribe button). The forbidden strings — "manage on our website", links to Stripe, billing URLs — are never rendered.
- The default `rishi` scheme uses the local `apps/apple/rishi/rishi/Rishi Reader.storekit` configuration for development. The shared `rishi (Sandbox)` scheme sets StoreKit Configuration to `None`, so device/TestFlight testing uses App Store Connect Sandbox products.

## Gotchas

- Never call `AppStore.sync()` opportunistically — Apple shows a sign-in prompt every time. Only call it from the user-initiated Restore button.
- Receipt verification goes through the worker, not directly to Apple, because the worker is the source of truth for the entitlement record.

---

**Next:** [onboarding.md](onboarding.md) — first-run flow.

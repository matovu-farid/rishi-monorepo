# Cross-platform Apple subscriptions design

## Goal

Offer equivalent Reader and Voice subscriptions on iOS and macOS without
showing the wrong platform's products or requiring a customer to pay twice.

## Product model

The existing `Rishi Reader & Voice` App Store Connect subscription group
remains the single logical group. Each existing iOS plan gets an equivalent
macOS product with its own product identifier. The product IDs are mapped to
the same internal plan (`reader` or `voice`) and duration metadata. The legacy
Pro products remain grandfathered and are not changed.

The exact macOS product IDs will be confirmed from the App Store Connect
product records before code is finalized. The code must not guess or silently
accept arbitrary product IDs.

## Native paywall

`SubscriptionStoreView(groupID:)` remains the purchase UI. Because the group
contains products for both platforms, the app must provide a platform-scoped
product catalog to the native view rather than relying on the group initializer
to merchandise every group product. The iOS build shows iOS products and the
macOS build shows macOS products, preserving StoreKit's group ranking and
upgrade/downgrade behavior within the platform catalog.

The same filtering rule is used by direct product loading, restore handling,
and any transaction-to-plan mapping. A product from the other platform must
never be offered for purchase by the current build.

## Shared entitlement

Apple transaction verification accepts every configured iOS and macOS product
ID. The Worker maps platform-specific product IDs to the same plan and stores
the transaction against the signed-in user using the existing app-account
token/account binding. `has_pro` and allowance entitlement queries remain
platform-neutral: an active Apple subscription from either platform grants the
same account entitlement.

Current-entitlement replay, transaction updates, App Store Server
Notifications, and restore all use the same product map. Product IDs are
validated against the explicit allow-list and never by a loose prefix.

## Verification

- Unit tests prove platform filtering for iOS and macOS catalogs.
- Unit tests prove every macOS product maps to the same plan and duration as
  its iOS counterpart.
- Worker tests prove macOS products pass verification, map to the correct
  allowance, and grant the same account entitlement.
- Existing iOS subscription and legacy Pro tests remain green.
- App Store Connect records and product IDs are manually verified before the
  final code claim.

## Adversarial review

- Critical risk: accidentally creating a second subscription group and causing
  double billing. Mitigation: use the existing Reader/Voice group only.
- High risk: native group paywall displays cross-platform products. Mitigation:
  platform-scoped product IDs/catalog and tests for both platforms.
- High risk: Worker rejects or misclassifies macOS transactions. Mitigation:
  one explicit product map shared by verification, webhook, and entitlement
  allowance logic.
- Medium risk: a customer buys on one platform but the other app remains
  locked. Mitigation: shared signed-in account plus server-side entitlement
  lookup and current-entitlement synchronization.

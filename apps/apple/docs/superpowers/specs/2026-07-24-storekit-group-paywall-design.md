# StoreKit Group-Based Paywall Design

> **Status:** Approved by user; implementation in progress.

## Goal

Make the Apple paywall load every subscription Apple exposes in the Reader & Voice subscription group (`22247412`) instead of restricting the paywall to a client-maintained product-ID list.

## Current behavior

- `GET /api/groupID` already returns `22247412` from the Worker.
- `GroupIDEndpoint` already fetches that response during service bootstrap.
- `BootstrappedServices.groupID` already carries the fetched value to the app.
- `LibraryTabView` already checks that the value exists before presenting the paywall.
- `SubscriptionsView` currently ignores the fetched value and calls `SubscriptionStoreView(productIDs:)` with four explicit IDs.

## Design

Pass the fetched group ID from `LibraryTabView` into `SubscriptionsView`, then use `SubscriptionStoreView(groupID:)`. StoreKit will load and merchandise all subscriptions in that App Store Connect group. Product ID constants remain for transaction/entitlement logic, but `paywallDisplayOrder` no longer controls the paywall catalog.

The local StoreKit configurations will use `22247412` as the Reader & Voice group ID so local StoreKit testing exercises the same group-based lookup as Sandbox. The legacy Pro group remains separate and is not part of this paywall.

## Failure behavior

If the Worker group-ID request fails, the existing `LibraryTabView` fallback continues to show “Plans unavailable” rather than presenting a paywall with an invalid group ID.

## Testing

- Add a pure UI-facing construction test or compile-level contract that pins the paywall to the fetched group ID rather than `paywallDisplayOrder`, using the project’s existing test conventions.
- Parse both StoreKit configuration files as JSON and assert the Reader & Voice group ID is `22247412`.
- Run the focused Apple billing tests and the relevant app build/test command available in the workspace.

## Out of scope

- Creating or changing App Store Connect products or prices.
- Adding a new Worker endpoint; `/api/groupID` already exists.
- Removing product-ID constants used by entitlement and transaction code.
- Changing the legacy Pro subscription group.

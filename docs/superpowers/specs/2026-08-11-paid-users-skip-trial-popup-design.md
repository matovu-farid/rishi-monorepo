# Paid users skip the free-trial intro popup

> **Status:** Design approved; implementation pending.

## Goal

During signed-in onboarding, do not present the no-card free-trial intro to a user whose fresh server-owned entitlement snapshot reports an active paid subscription. Preserve the current popup for unpaid users and for cases where entitlement cannot be confirmed.

## Behavior contract

The popup eligibility decision uses the result of the server entitlement refresh:

| Fresh refresh result | Popup | Mark intro seen |
| --- | --- | --- |
| `readerActive` or `voiceActive` | No | No |
| Trial, exhausted, or expired | Yes | Yes |
| Refresh failure / unavailable result | Yes | Yes |

The StoreKit-only entitlement signal is not used as an override. A cached paid snapshot must not suppress the popup when the fresh refresh fails; failure follows the existing safe fallback of showing it.

## Design

`EntitlementRefreshCoordinator.refreshIfSignedIn` will return an optional fresh `Result<EntitlementSnapshot, Error>`: `nil` when no user is signed in, otherwise the exact success or failure returned by `EntitlementService`. Existing callers that do not need the result may ignore it. The coordinator remains responsible for binding the signed-in user and coalescing concurrent refreshes only for the same account; work is tagged with the user ID so an account switch cannot reuse another account's result. The service will validate that the expected account is still current before applying a network response or persisting it, and a stale response must not clear the newer account's in-memory state.

`RootView.presentNoCardTrialIntroIfNeeded` will use a main-actor in-flight gate so repeated library-ready callbacks cannot overlap the entitlement check. It will:

1. Verify that the account is signed in and has not already seen the intro.
2. Await the coordinated server entitlement refresh.
3. Suppress the popup only for a successful paid snapshot.
4. Re-check the signed-in account and seen flag after the await.
5. Mark the account as having seen the intro, then re-check the account once more before presenting.

The seen flag is set only on the presentation path. If the account changes during the asynchronous write, the write is compensated by clearing the old account's flag and no popup is presented. This allows a paid user who later becomes unpaid to receive the intro, while retaining the existing per-account behavior once the intro has been shown.

## Components and ownership

- `EntitlementRefreshCoordinator`: returns the authoritative refresh outcome while preserving account-scoped refresh coordination and launch-refresh promotion.
- `RootView`: owns the onboarding popup decision and applies the behavior contract.
- `EntitlementSnapshot.isPaidActive`: remains the single predicate for active paid server states.
- `TrialOnboardingState`: remains storage for whether the popup was shown; it does not become an entitlement store.

## Error handling and concurrency

Refresh errors, including an account-change invalidation, are treated as unknown entitlement and therefore show the popup. A coalesced refresh returns the same outcome to all waiting callers for the same account. The coordinator keeps forced-refresh generations distinct, promotes a coalesced launch request when the existing task does not include launch reconciliation, and keeps launch reconciliation inside the in-flight operation. The RootView in-flight gate plus the post-refresh and post-write account/seen checks prevents repeated library-ready callbacks from presenting the intro more than once per account.

## Testing

Add focused tests in the `rishiTests` target for the popup decision contract:

- paid reader and voice snapshots do not qualify for presentation;
- trial/unpaid snapshots qualify for presentation;
- an unknown or failed refresh follows the presentation fallback.

Add or update coordinator coverage to verify that the fresh refresh result is returned, including a failure result. Run the focused tests and the relevant Apple target build where the local Xcode installation permits it.

Coordinator tests must also cover launch promotion over a non-launch in-flight task, account-switch invalidation before response application (with the expected account unresolved and its disk cache preserved), a late old-account response after the new account has hydrated (with the new account's in-memory state preserved), and shared-result account revalidation. RootView integration coverage must assert the in-flight gate and compensating seen-flag clear; the source-level smoke test is intentionally limited to ordering and ownership because RootView's full dependency graph is not constructible in the package test target.

## Scope and non-goals

- Change only the no-card trial intro flow.
- Do not change paywall behavior, StoreKit reconciliation, subscription APIs, or entitlement server semantics.
- Do not add a new persisted entitlement field or alter migration/database code.

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

`EntitlementRefreshCoordinator.refreshIfSignedIn` will return an optional fresh `Result<EntitlementSnapshot, Error>`: `nil` when no user is signed in, otherwise the exact success or failure returned by `EntitlementService`. Existing callers that do not need the result may ignore it. The coordinator remains responsible for binding the signed-in user and coalescing concurrent refreshes.

`RootView.presentNoCardTrialIntroIfNeeded` will:

1. Verify that the account is signed in and has not already seen the intro.
2. Await the coordinated server entitlement refresh.
3. Suppress the popup only for a successful paid snapshot.
4. Otherwise mark the account as having seen the intro and present the popup.

The seen flag is set only on the presentation path. This allows a paid user who later becomes unpaid to receive the intro, while retaining the existing per-account behavior once the intro has been shown.

## Components and ownership

- `EntitlementRefreshCoordinator`: returns the authoritative refresh outcome while preserving refresh coordination.
- `RootView`: owns the onboarding popup decision and applies the behavior contract.
- `EntitlementSnapshot.isPaidActive`: remains the single predicate for active paid server states.
- `TrialOnboardingState`: remains storage for whether the popup was shown; it does not become an entitlement store.

## Error handling and concurrency

Refresh errors are treated as unknown entitlement and therefore show the popup. A coalesced refresh returns the same outcome to all waiting callers. The existing seen-state guard remains in place so repeated library-ready callbacks do not intentionally show the intro more than once per account.

## Testing

Add focused tests in the `rishiTests` target for the popup decision contract:

- paid reader and voice snapshots do not qualify for presentation;
- trial/unpaid snapshots qualify for presentation;
- an unknown or failed refresh follows the presentation fallback.

Add or update coordinator coverage to verify that the fresh refresh result is returned, including a failure result. Run the focused tests and the relevant Apple target build where the local Xcode installation permits it.

## Scope and non-goals

- Change only the no-card trial intro flow.
- Do not change paywall behavior, StoreKit reconciliation, subscription APIs, or entitlement server semantics.
- Do not add a new persisted entitlement field or alter migration/database code.

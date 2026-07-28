# Subscription State Paywall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make active subscriptions show management instead of Subscribe, preserve upgrade choices, dismiss after successful purchase, confirm success, and make restore errors understandable.

**Architecture:** Keep `SubscriptionStoreView` for Apple-managed purchasing. Add a small app-owned state adapter around the existing entitlement snapshot and StoreKit group ID, use `visibleRelationships: .upgrade` for active subscribers, and route purchase completion through the existing root callback plus the Settings sheet callback. Restore remains user initiated through `RestoreService`.

**Tech Stack:** SwiftUI, StoreKit 2, Observation, Swift Testing, existing `EntitlementSnapshotStore`, `ManageSubscriptionPresenter`, and `RestoreService`.

---

## Files and responsibilities

- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`: render active-plan management, upgrade-only StoreKit content, completion callback, and friendly restore messages.
- Modify `apps/apple/rishi/rishi/Settings/SettingsContent.swift`: own the success confirmation after its subscription sheet dismisses and pass the resolved paid state/group ID into the paywall.
- Modify `apps/apple/rishi/rishi/RootView.swift`: connect native purchase completion to transaction processing, refresh, dismissal/confirmation state for the Catalyst presentation path, and avoid duplicate completion handling.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/RestoreService.swift`: expose stable user-facing restore messaging through typed outcomes without leaking raw errors at the view boundary.
- Add `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/SubscriptionPaywallStateTests.swift`: test paid/unpaid action state and restore message mapping.
- Update `apps/apple/rishi/rishiTests/PackageTests/RishiSettings/RishiSettingsTests/SettingsScreenSmokeTests.swift` only if the changed callback/API requires fixture updates.

## Implementation order

### Task 1: Add failing state and restore-message tests

- [ ] Add pure tests for the paywall decision: unpaid → `.subscribe`; paid → `.manage`; paid active plan is not included in the upgrade product set.
- [ ] Add pure tests mapping `.nothingToRestore` to “No purchases were found to restore.” and typed restore errors to recovery copy without including `String(describing:)` output.
- [ ] Run the focused StoreKit test target and confirm the new tests fail for the missing state adapter/message API.

### Task 2: Implement paywall state and StoreKit presentation

- [ ] Add a small internal value type in `SubscriptionsView.swift` containing `isPaid`, `activeProductID` when known, `visibleRelationships`, and the current-plan label; keep it independent of SwiftUI for testability.
- [ ] Read the existing resolved entitlement snapshot and StoreKit status source at the presentation boundary. Do not treat the server snapshot as proof that a product is currently purchasable; use StoreKit’s subscription group relationship for the native picker.
- [ ] For unpaid users, retain the existing `SubscriptionStoreView(productIDs:)` path.
- [ ] For paid users with the configured subscription group, use `SubscriptionStoreView(groupID:visibleRelationships: .upgrade)` and show the app-owned current-plan card with `Manage Subscription`. Leave the native StoreKit upgrade CTA intact.
- [ ] Preserve policy links, account token binding, catalog failure/retry behavior, and Restore Purchases in both paths.
- [ ] Add accessibility labels that distinguish “Current plan” and “Upgrade plan.”

### Task 3: Complete purchases and confirmation

- [ ] Add an `onPurchaseCompleted` closure to `SubscriptionsView` with a default no-op so existing call sites remain source-compatible.
- [ ] Add `.onInAppPurchaseCompletion` to the paywall only where the paywall is presented, process only `.success(.verified(...))`, await `Store.process(purchaseResult:)`, refresh entitlements, and invoke the callback on the main actor.
- [ ] Do not dismiss for `.pending`, `.userCancelled`, unverified results, or thrown purchase errors.
- [ ] In `SettingsContent`, set a confirmation state from the callback, dismiss the sheet, refresh in `onDismiss`, and show a standard alert after dismissal with “Subscription active” and “Thank you for subscribing.”
- [ ] Keep the existing Catalyst/root completion path single-owner: it must process the purchase and refresh once, then dismiss its subscription sheet and show the same confirmation.

### Task 4: Friendly restore behavior

- [ ] Keep `RestoreService.restore()` typed as `.restored`, `.nothingToRestore`, or `RestoreError`; do not alter the StoreKit sync semantics.
- [ ] Add a view-local mapping for `RestoreError.syncFailed` and `.entitlementSyncFailed` to stable recovery text: “We couldn’t verify your purchases right now. Check your Apple ID connection and try again.”
- [ ] Keep `.nothingToRestore` as a normal informational result, not an error alert.
- [ ] Add a log event with the diagnostic error internally, while showing only the stable message to users.

### Task 5: Verify and review

- [ ] Run focused Swift tests for paywall state and restore messaging.
- [ ] Run the existing RishiBilling StoreKit tests and Settings smoke tests.
- [ ] Build the iOS target with the approved `xcodebuild` command.
- [ ] Manually verify four flows in StoreKit Test/Sandbox: new purchase dismisses and confirms; active Reader plan shows Manage plus Voice upgrades; pending/cancelled purchase stays open; restore with no entitlements gives normal informational copy.
- [ ] Re-read the diff for duplicate purchase completion processing, stale paid state after sign-out, and accidental removal of Restore Purchases or policy links.

## Consumer / call-site audit

| Consumer | Current behavior | Required change |
|---|---|---|
| `SettingsContent` | Presents `SubscriptionsView` and refreshes only on dismiss | Pass paid state/group ID, handle success confirmation after dismiss |
| `RootView` Catalyst path | Processes global purchase completion but does not confirm/dismiss iOS Settings sheet | Keep Catalyst ownership explicit and avoid duplicate processing |
| `LibraryTabView` | Presents subscriptions for upgrade prompts | Use same paywall state and callback contract |
| `BillingSection` | Already shows Manage for paid server snapshot | Preserve; no new purchase path |
| `ManageSubscriptionRow` | Opens Apple management UI | Reuse for current-plan card |
| `RestoreService` | Typed outcome/error, view leaks localized raw error | Preserve service contract, sanitize view copy |

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `SubscriptionsView` is presented from multiple owners; a callback only on one path could leave Library or Catalyst flows without dismissal. | Audit and update `SettingsContent`, `RootView`, and `LibraryTabView`; give the callback a default and retain refresh-on-dismiss for every owner. |
| 2 | High | The server paid snapshot cannot identify the exact StoreKit product or prove that an upgrade relationship exists. | Use the snapshot only to choose paid/unpaid presentation; let `SubscriptionStoreView(groupID:visibleRelationships: .upgrade)` determine StoreKit products. |
| 3 | High | Global `.onInAppPurchaseCompletion` and a local paywall callback could process the same transaction twice. | Define one completion owner per presentation path; local iOS paywall handles its own completion, Catalyst root handles its own, and tests assert no duplicate processing. |
| 4 | Medium | StoreKit Test transactions may be rejected by the worker, making “verified purchase” ambiguous in local testing. | Treat StoreKit verification as required for success UI; document Sandbox/TestFlight as the acceptance environment for the end-to-end confirmation. |

**Round 1 result:** Re-review required; plan updated with explicit owners and StoreKit relationship authority.

### Round 2 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `SettingsContent`’s sheet is the iOS owner, but `LibraryTabView` may use a separate sheet; a parent alert must not be presented behind a still-visible sheet. | Require each owner to set confirmation only after its sheet binding becomes false; keep the callback and dismissal state in the owner, not the paywall. |
| 2 | High | If the active product is not known, a paid user could see an upgrade-only view with no upgrade products. | Require the native group-based view to load its own group products and show an unavailable/retry state if StoreKit returns no valid upgrades; never hide all purchase affordances silently. |
| 3 | Medium | Settings already uses `ManageSubscriptionRow`; adding a second implementation could drift behavior. | Reuse `ManageSubscriptionRow` in the current-plan card rather than duplicating `AppStore.showManageSubscriptions` logic. |

**Round 2 result:** PASS — 0 open Critical/High issues; implementation may begin.

### Round 3 — Implementation re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The first implementation used only the server entitlement snapshot, so StoreKit could show `Your Plan` while Settings still showed `Subscribe` during entitlement-sync lag. | Added `CustomerEntitlements.hasActiveSubscription(in:)` and use the live StoreKit group status OR the server snapshot for paywall and Settings action selection. |
| 2 | Medium | Focused tests could not run because the requested iPhone 16 simulator is not installed; the full test target also contains unrelated pre-existing auth compilation failures. | Re-ran against the installed iPhone 17 destination; source target build succeeds. Record test-environment limitation and do not claim the whole suite passes. |

**Round 3 result:** PASS — 0 open Critical/High issues in the implementation diff; remaining test-suite issue is unrelated repository baseline/environment debt.

### Round 4 — Allowance display re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | StoreKit correctly selected `Manage Subscriptions`, but `BillingSection` still passed a stale server `.trialActive` snapshot to `RemainingAllowanceView`, exposing free-trial credits after purchase. | Thread `storeKitIsSubscribed` into the allowance view and render “Updating subscription allowance…” until the server returns a paid period; paid-period allowances continue to render normally. |
| 2 | Medium | A StoreKit Test/server-sync delay must not be mistaken for a zero paid allowance. | Suppress trial/exhausted/expired copy only while StoreKit reports an active subscription; retain the server’s paid allowance as soon as it arrives. |

**Round 4 result:** PASS — 0 open Critical/High issues; no free-trial credit amount is rendered for a StoreKit-active subscription during entitlement-sync lag.

### Round 5 — Platform catalog re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The subscription-group initializer can merchandise all products in the shared group, including macOS plans, on iOS. | Use `RishiProductID.currentPlatformPaywallProductIDs` for the native StoreKit view; the iOS build now passes only its four iOS IDs, while Catalyst retains its four macOS IDs. |
| 2 | Medium | A group-wide upgrade relationship filter is not compatible with strict platform filtering. | Keep the app-owned Manage Subscription row and use the explicit platform catalog for the StoreKit sheet. |

**Round 5 result:** PASS — 0 open Critical/High issues; the paywall catalog is platform-scoped.

### Round 6 — Native management-sheet re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The reported eight-product screen is Apple's native management sheet, which ignores the app's product-ID list and reads every product in the shared subscription group. | Route the app's primary “Change Subscription” action to the filtered Rishi paywall; retain a separately labeled “Manage with Apple” entry for cancellation and account management. |
| 2 | Medium | Removing Apple's management entry entirely would make cancellation harder and create a compliance risk. | Preserve the native Apple entry as an explicit secondary action rather than pretending it can be filtered. |

**Round 6 result:** PASS — the app-owned plan-change flow is platform-scoped while Apple-native cancellation remains available.

### Round 7 — Subscription-group safety decision

**Decision:** Keep the iOS and macOS equivalents in one Apple subscription group. Splitting groups would allow separate simultaneous subscriptions and duplicate billing. The app therefore uses its own platform-filtered picker for plan changes and a clearly labeled Apple-native cancellation action.

### Restore UX decision

StoreKit restores active subscriptions automatically from `Transaction.currentEntitlements`. The explicit `AppStore.sync()` fallback remains on the unpaid/recovery paywall, where it can be invoked by an intentional user action, but is hidden for already-active subscribers to avoid redundant UI.

## Explicitly out of scope

- Changing App Store Connect metadata or submission state.
- Changing worker APIs or database schema.
- Replacing native StoreKit purchase controls with a custom payment flow.

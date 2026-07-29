# Catalyst Subscription Parity Implementation Plan

> **Status:** Adversarial review loop complete — **PASS WITH NOTES** (2 rounds, 0 open Critical/High issues; simulator test execution remains environment-blocked)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Catalyst subscription experience follow the approved iOS behavior while retaining Mac-specific products and Apple-native management.

**Architecture:** Keep `SubscriptionsView` as the shared StoreKit presentation boundary. Extract only pure presentation decisions into testable values/functions; leave StoreKit purchase, entitlement refresh, and Apple management APIs in the existing view. Use the existing `onPurchaseCompleted` callback to dismiss the caller-owned sheet and show confirmation.

**Tech Stack:** SwiftUI, StoreKit 2, Swift Testing, Xcode Catalyst build.

---

## Files and ownership

- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`: shared paywall presentation and completion behavior.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/UI/ManageSubscriptionRow.swift` only if Catalyst management labeling or presentation needs correction.
- Test `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/SubscriptionPaywallStateTests.swift`: pure active/inactive presentation rules.
- Test `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/Models/RishiProductIDTests.swift` if the existing product-ID test location requires platform-order coverage.

## Task 1: Confirm the failing behavior contract

- [ ] Add pure tests proving an active subscriber uses `.manage` and `.upgrade`, while an inactive user uses `.subscribe` and `.all`.
- [ ] Add/extend tests proving the Catalyst product set contains exactly four `.macos` IDs and excludes iOS IDs.
- [ ] Run the focused Swift tests and verify the new assertions fail if the current decision logic is changed or absent; do not change production behavior before observing the test result.

## Task 2: Implement parity behavior

- [ ] Keep `SubscriptionPaywallPresentation` as the single source of truth for active/inactive state.
- [ ] Ensure `SubscriptionStoreView` receives `visibleRelationships` from that presentation value on all platforms.
- [ ] Keep the active subscriber marketing block with current-plan state, Apple management, and upgrade explanation; keep Restore Purchases gated behind `!isPaidActive`.
- [ ] Ensure verified purchase completion processes the transaction, refreshes server entitlement, and calls `onPurchaseCompleted()` only after those operations finish.
- [ ] Add a caller-visible confirmation path using the existing callback contract without introducing a second purchase implementation or changing StoreKit product IDs.
- [ ] Keep Catalyst sizing wide enough for the shared paywall and preserve the existing native StoreKit sheet.

## Task 3: Verify behavior and release readiness

- [ ] Run the focused billing tests.
- [ ] Run the existing iOS billing tests to detect regressions.
- [ ] Run a Catalyst Release build using `generic/platform=macOS,variant=Mac Catalyst` in a fresh derived-data directory.
- [ ] Review the diff for accidental changes to platform IDs, subscription-group behavior, or worker entitlement synchronization.

## Adversarial review loop

Each round: review → log findings → update the plan → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan must not assume Catalyst can use the iOS-only product IDs. | Explicitly retain `RishiProductID.currentPlatformPaywallProductIDs` and add a four-Mac-ID test. |
| 2 | High | A purchase must not dismiss before entitlement processing completes. | Require `store.process`, worker entitlement refresh, then `onPurchaseCompleted()`. |
| 3 | Medium | “Similar to iOS” could accidentally replace Apple’s cancellation flow. | Keep `AppleManageSubscriptionRow` and native management explicitly in scope. |

**Round 1 result:** Re-review required for implementation verification.

### Round 2 — Implementation re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The existing completion callback already dismisses the caller-owned sheet and shows the confirmation alert; duplicating that behavior in the paywall would risk double alerts. | Reused the existing callback and changed only StoreKit relationship filtering and restore-state derivation. |
| 2 | Medium | Catalyst’s simulator test destination is unavailable because CoreSimulator cannot connect in this environment. | Catalyst Release compilation succeeded; focused test execution is recorded as pending a functioning simulator or physical Mac run. |
| 3 | Low | The native Apple management sheet can still show the shared subscription group’s products. | This is Apple-controlled and intentionally remains unchanged; the app paywall itself is explicitly platform-filtered. |

**Round 2 result:** PASS WITH NOTES — 0 open Critical/High issues.

### Consumer / call-site audit

| Consumer | Required invariant |
|---|---|
| `RootView.swift` | Purchase callback remains the dismissal boundary. |
| `Library/LibraryRootView.swift` | Library paywall remains platform-filtered and dismissible after purchase. |
| `Settings/SettingsContent.swift` | Settings subscription entry continues to show active/manage state. |
| `SubscriptionsView.swift` | StoreKit and entitlement state remain shared across iOS/Catalyst. |

## Explicitly out of scope

- App Store Connect product changes.
- Worker deployment or entitlement policy changes.
- Subscription group restructuring.
- Custom cancellation UI replacing Apple’s management sheet.
- Mac screenshots or release metadata.

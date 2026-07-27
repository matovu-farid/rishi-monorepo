# Mac Catalyst Subscription Menu Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
>
> **Status:** Adversarial review loop complete — **PASS** (2 rounds, 0 open Critical/High issues)

**Goal:** Make the Mac Catalyst account menu offer subscription purchase for users without an active entitlement and offer subscription management only to active subscribers, matching iOS Settings behavior.

**Architecture:** Keep the server-resolved `EntitlementSnapshot` as the UI source of truth, because it is already the source used by `BillingSection`. Extend the Catalyst account-menu payload with an explicit subscription action and purchase callback; the menu remains presentation-only. Reuse the existing `SubscriptionsView` purchase flow and `ManageSubscriptionPresenter` management flow.

**Tech Stack:** SwiftUI, Observation, StoreKit 2, Mac Catalyst, Swift Testing/XCTest targets.

---

### Task 1: Make the Catalyst account payload entitlement-aware

**Files:**
- Modify: `apps/apple/rishi/rishi/Mac/MacAccountMenuModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift`
- Modify: `apps/apple/rishi/rishi/Mac/RishiMenuCommands.swift`
- Modify: `apps/apple/rishi/rishi/Views/SignedInView.swift`

- [ ] Add a `SubscriptionAction` enum (`subscribe`, `manage`) and payload callbacks for both actions.
- [ ] In the Catalyst publisher, read the same `EntitlementSnapshotStore.resolvedSnapshot` used by Settings and map `isPaidActive == true` to `manage`, otherwise `subscribe`.
- [ ] Wire subscribe to the existing app-owned `SubscriptionsView` presentation mechanism and manage to `ManageSubscriptionPresenter`.
- [ ] Render exactly one menu item: `Subscribe…` for inactive/unknown state and `Manage Subscription…` for active state.
- [ ] Preserve sign-out, legal links, and account lifecycle cleanup.

### Task 2: Verify purchase and management routing

**Files:**
- Modify: `apps/apple/rishi/rishiTests/Mac/MacReaderPrefsMenuViewModelTests.swift`

- [ ] Add tests proving inactive state exposes subscribe and active state exposes manage.
- [ ] Add tests proving each callback invokes only its corresponding injected action.
- [ ] Run the focused Mac tests and the Catalyst compile/test command available in the repository.

## Consumer / call-site audit

| Consumer | Required behavior |
|---|---|
| Catalyst account menu | Display and invoke subscribe/manage based on resolved snapshot |
| Settings `BillingSection` | Remains unchanged and continues using `isPaidActive` |
| iOS purchase UI | Remains unchanged; uses `SubscriptionsView` |
| Sign-out/disappear lifecycle | Clear account payload and callbacks |

## Implementation order

1. Update payload and view-model contracts.
2. Update publisher wiring and menu rendering.
3. Add focused tests.
4. Build/test and review the complete diff.

## Explicitly out of scope

- Changing StoreKit product identifiers.
- Changing backend entitlement calculation or allowance periods.
- Changing the existing iOS Settings subscription UI.
- Adding a separate Catalyst purchase implementation.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The Catalyst account menu is hardcoded to management and has no purchase callback. | Task 1 adds an explicit action enum and both callbacks. |
| 2 | High | Using StoreKit-only state would diverge from the existing iOS Settings source of truth. | Task 1 explicitly reuses `EntitlementSnapshotStore.resolvedSnapshot`. |
| 3 | Medium | Unknown/loading entitlement state must not expose management. | Plan maps only `isPaidActive == true` to manage; all other states show subscribe. |

**Round 1 result:** Re-review required for the loading/unknown and lifecycle cases.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The menu must not leave stale callbacks after sign-out or view disappearance. | Consumer audit and Task 1 explicitly preserve `clear()` lifecycle cleanup. |
| 2 | Low | Existing Settings behavior should not be changed as part of Catalyst parity. | Explicitly out of scope and consumer audit added. |

**Round 2 result:** PASS — 0 open Critical/High issues.

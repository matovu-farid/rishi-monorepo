# Catalyst Manage Subscription Presenter Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the missing `ManageSubscriptionPresenter` dependency in the Catalyst service graph so the Mac preferences menu compiles and can open subscription management.

**Architecture:** `ServiceGraphFactory.build()` constructs one main-actor-owned presenter, stores it in `BootstrappedServices`, and the Catalyst-only `MacReaderPrefsMenuViewModel` consumes that shared instance through its existing closure. No billing implementation or iOS behavior changes are required.

**Tech Stack:** Swift 6, SwiftUI, Observation, RishiBilling, Xcode Mac Catalyst.

---

## Scope and file map

| File | Responsibility | Planned change |
|---|---|---|
| `apps/apple/rishi/rishi/AppDependencies.swift` | Service aggregate | Add `manageSubscriptionPresenter`. |
| `apps/apple/rishi/rishi/ServiceGraphFactory.swift` | Service construction | Retain the presenter and pass it into the aggregate. |
| `apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift` | Catalyst menu adapter | No change; preserve its existing consumer. |
| `apps/apple/rishi/rishi/Views/SignedInView.swift` | Catalyst handoff | No change; verify the existing handoff. |
| `apps/apple/rishi/rishiTests/Mac/MacReaderPrefsMenuViewModelTests.swift` | Catalyst behavior tests | Existing direct-closure tests remain; the service-graph path is verified by Catalyst compilation. |

## Consumer / call-site audit

| Consumer | Platform gate | Expected result |
|---|---|---|
| `MacReaderPrefsMenuViewModel` convenience initializer | `#if targetEnvironment(macCatalyst)` | Reads the restored property and injects `await presenter.present()`. |
| `ReaderPrefsMenuPublisher` in `SignedInView` | `#if targetEnvironment(macCatalyst)` | Continues passing `BootstrappedServices`. |
| iOS app paths | Not Catalyst | Remain behaviorally unchanged. |

## Implementation order

Task 1 captures the red compiler signal. Task 2 restores the dependency. Task 3 verifies Catalyst and existing tests. Task 4 performs the final diff gate.

### Task 1: Capture the failing Catalyst build

**Files:** None.

- [ ] **Step 1: Check the worktree.**

```bash
git status --short
```

Expected: preserve the existing ActivityKit/Catalyst changes and all unrelated user work.

- [ ] **Step 2: Run the red baseline.**

```bash
xcodebuild -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/rishi-catalyst-manage-presenter-derived build
```

Expected: failure at `MacReaderPrefsMenuViewModel.swift:165` stating that `BootstrappedServices` has no `manageSubscriptionPresenter`. If another failure masks it, record the exact blocker and still verify the source mismatch.

### Task 2: Restore the presenter in the service graph

**Files:**
- Modify: `apps/apple/rishi/rishi/AppDependencies.swift:150-160`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift:338-344,393-452`

- [ ] **Step 1: Add the aggregate property.**

Replace the commented placeholder with:

```swift
let manageSubscriptionPresenter: ManageSubscriptionPresenter
```

Keep it with the entitlement/billing dependencies. Do not make it optional or construct a second presenter.

- [ ] **Step 2: Retain the factory-created instance.**

Replace:

```swift
let _ = await MainActor.run {
    ManageSubscriptionPresenter()
}
```

with:

```swift
let manageSubscriptionPresenter = await MainActor.run {
    ManageSubscriptionPresenter()
}
```

This preserves the presenter’s `@MainActor` construction requirement.

- [ ] **Step 3: Pass it into `BootstrappedServices`.**

Add this argument in the entitlement section:

```swift
manageSubscriptionPresenter: manageSubscriptionPresenter,
```

Do not change `ManageSubscriptionPresenter.present()`, StoreKit behavior, or the Catalyst view model.

- [ ] **Step 4: Audit references and formatting.**

```bash
rg -n "manageSubscriptionPresenter|BootstrappedServices\(" apps/apple/rishi/rishi --glob '*.swift'
git diff --check
```

Expected: declaration, factory local, aggregate argument, and Catalyst consumer are all present; no whitespace errors.

### Task 3: Verify Catalyst and existing behavior

**Files:** No additional files expected.

- [ ] **Step 1: Run the existing Catalyst-gated view-model tests.**

Run the named test suite directly:

```bash
xcodebuild test -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/rishi-catalyst-manage-presenter-tests -only-testing:rishiTests/MacReaderPrefsMenuViewModelTests
```

Expected: the Catalyst-gated manage-subscription callback tests pass. These tests exercise the view-model callback behavior, not construction of the full `BootstrappedServices` graph; the full Catalyst build in Step 2 is the verification that the `services:` initializer and aggregate member compile together. If Xcode rejects the destination/test identifier, or an unrelated dependency fails before tests run (for example `PropertyBased` reporting `NSColor` unavailable in Mac Catalyst), record the test run as unavailable and use the full Catalyst build as compile verification.

- [ ] **Step 2: Run a fresh full Catalyst build.**

```bash
xcodebuild -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/rishi-catalyst-manage-presenter-derived-green build
```

Expected: the missing-member error is absent and the build exits 0. Report any unrelated file/line failure separately; do not expand scope.

- [ ] **Step 3: Run an iOS build to protect shared behavior.**

```bash
xcodebuild build -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath /private/tmp/rishi-ios-manage-presenter-derived
```

Expected: the shared service graph still compiles for iOS. If the named simulator is unavailable, use an installed iOS Simulator destination and record the exact substitution; report unrelated pre-existing failures separately.

- [ ] **Step 4: Confirm the diff is limited.**

```bash
git diff -- apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift apps/apple/rishi/rishi/Views/SignedInView.swift
git status --short apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/Mac/MacReaderPrefsMenuViewModel.swift apps/apple/rishi/rishi/Views/SignedInView.swift apps/apple/docs/superpowers/plans/2026-07-24-catalyst-manage-subscription-wiring.md
```

Expected: only the aggregate and factory change among source files; Catalyst consumer and iOS paths are unchanged, and the plan itself is the only expected new documentation file.

### Task 4: Final review gate

- [ ] **Step 1: Run final checks.**

```bash
git diff --check
git status --short
```

Expected: only intended files are modified for this fix; no generated build output is in the repository.

- [ ] **Step 2: Report handoff.**

Report exact files changed, Catalyst build result, unrelated blockers, and commit status. Do not claim success unless the fresh verification command exits 0.

## Explicitly out of scope

- Hiding/removing the Catalyst manage-subscription action.
- Changing StoreKit, `ManageSubscriptionPresenter`, entitlements, purchase behavior, or billing UI.
- Refactoring `BootstrappedServices`.
- Fixing unrelated Catalyst compiler errors.
- Reworking the existing ActivityKit Catalyst guards.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | The plan must preserve one shared presenter rather than constructing one in the view model. | Task 2 retains the factory-created instance and injects it through `BootstrappedServices`; the view model is unchanged. |
| 2 | High | Existing uncommitted ActivityKit changes must not be overwritten. | Task 1 requires a status check and preservation of unrelated work. |
| 3 | Medium | The full Catalyst build may reveal unrelated failures. | Task 3 requires reporting unrelated failures separately and keeps them out of scope. |

**Round 1 result:** High findings resolved in the artifact; re-review required.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | Existing unit tests bypass the `BootstrappedServices` convenience initializer and cannot prove the presenter is forwarded from the service graph. | Task 3 now states this limitation explicitly and makes the full Catalyst build the compile-time verification for the service-graph path. |
| 2 | Medium | The shared aggregate/factory changes need an iOS build check to support the claim that iOS behavior remains unchanged. | Task 3 adds an explicit iOS Simulator build gate. |
| 3 | Low | The source-only diff command omitted the untracked plan file. | Task 3 adds a scoped `git status --short` including the plan path. |

**Round 2 result:** Medium findings resolved in the artifact; re-review required.

### Round 3 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The focused Catalyst test command can fail in the unrelated `PropertyBased` dependency before the named tests run. | Task 3 now explicitly treats pre-test dependency failures as an unavailable test run and directs verification to the full Catalyst build. |

**Round 3 result:** Medium finding resolved in the artifact; re-review required.

### Round 4 — Re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | — | No open Critical, High, or Medium findings after documenting the known dependency-level test limitation and fallback. | Closed. |

**Round 4 result:** PASS — 0 open Critical/High/Medium issues.

## Plan completion status

> **Status:** Adversarial review loop complete — **PASS** (4 rounds, 0 open Critical/High/Medium issues)

# StoreKit Group Paywall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing Worker-provided App Store subscription group ID (`22247412`) into the Apple paywall so StoreKit loads the complete Reader & Voice group.

**Architecture:** Keep `/api/groupID` and `GroupIDEndpoint` as the group-ID source of truth. Thread the already-fetched `GroupId` from `LibraryTabView` into `SubscriptionsView`, and replace the explicit `productIDs` initializer with StoreKit’s `groupID` initializer. Align both local StoreKit JSON fixtures with the live group identifier.

**Tech Stack:** SwiftUI, StoreKit 2 `SubscriptionStoreView`, Swift Testing, StoreKit configuration JSON, Cloudflare Worker/Hono.

---

## Files and responsibilities

- Modify `apps/apple/rishi/rishi/Library/LibraryTabView.swift`: pass `services.groupID.value` into the paywall.
- Modify `apps/apple/rishi/rishi/Settings/SettingsContent.swift`: pass `services.groupID.value` into the settings paywall.
- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`: accept a group ID and use `SubscriptionStoreView(groupID:)`.
- Modify `apps/apple/rishi/Rishi Reader.storekit`: change only the Reader & Voice group ID to `22247412`.
- Modify `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit`: change only the Reader & Voice group ID to `22247412`.
- Add/update the narrowest existing Apple test that can verify the group-ID contract; if no UI target can test the view construction without StoreKit runtime state, use a JSON/configuration contract test and verify source call sites by build.

## Task 1: Write the failing configuration contract test

**Files:**
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/StoreKit/StoreKitConfigTests.swift`

- [ ] **Step 1: Add a test that loads the bundled fixture and expects the Reader & Voice group ID to be `22247412`.**

The test must decode the fixture resource, locate the subscription group containing `org.fidexa.rishi.voice.monthly`, and assert that group’s `id` equals `22247412`.

- [ ] **Step 2: Run the focused test and confirm it fails against the current fixture.**

Run from `apps/apple/Packages/RishiBilling`:

```bash
swift test --filter StoreKitConfigTests
```

Expected result: the new assertion fails because the current fixture uses `rishi-reader-voice-group`.

## Task 2: Implement group-based paywall wiring

**Files:**
- Modify: `apps/apple/rishi/rishi/Library/LibraryTabView.swift:186-188`
- Modify: `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift:6-50`

- [ ] **Step 1: Change `SubscriptionsView` to require the fetched group ID.**

Add a stored property and initializer:

```swift
private let groupID: String

public init(groupID: String) {
    self.groupID = groupID
}
```

Replace:

```swift
SubscriptionStoreView(productIDs: RishiProductID.paywallDisplayOrder) {
```

with:

```swift
SubscriptionStoreView(groupID: groupID) {
```

- [ ] **Step 2: Pass the fetched Worker value at the existing guarded call site.**

Replace `SubscriptionsView()` with:

```swift
SubscriptionsView(groupID: services.groupID!.value)
```

The surrounding `if services.groupID != nil` guard remains in place and preserves the existing unavailable-plans fallback.

- [ ] **Step 3: Update both local StoreKit fixtures.**

In each fixture, change only the Reader & Voice group object’s top-level `id` and its four `subscriptionGroupID` values from `rishi-reader-voice-group` to `22247412`. Do not change the legacy Pro group or product IDs.

- [ ] **Step 4: Run the configuration test and verify it passes.**

Run:

```bash
swift test --filter StoreKitConfigTests
```

Expected result: PASS.

## Task 3: Adversarial implementation review and verification

- [ ] **Step 1: Audit all `SubscriptionsView` call sites.**

Run:

```bash
rg -n 'SubscriptionsView\(' apps/apple --glob '*.swift'
```

Every call site must provide the fetched group ID; no call site may silently fall back to explicit product IDs.

- [ ] **Step 2: Validate both StoreKit files as JSON.**

Run:

```bash
python3 -c 'import json; json.load(open("apps/apple/rishi/Rishi Reader.storekit")); json.load(open("apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit")); print("OK")'
```

Expected output: `OK`.

- [ ] **Step 3: Run focused package tests.**

Run:

```bash
cd apps/apple/Packages/RishiBilling && swift test --filter StoreKitConfigTests
```

- [ ] **Step 4: Run the Apple build/test gate available for the project.**

Use the project’s configured `xcodebuild` destination and report any simulator/toolchain limitation separately from source failures.

## Adversarial review loop

Each round: review → log findings → update plan → re-review.

### Round 1 — Plan review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | The app already fetches `/api/groupID`; adding a second endpoint would create competing sources of truth. | Plan explicitly reuses `GroupIDEndpoint` and adds no Worker endpoint. |
| 2 | High | `SubscriptionsView` currently has a zero-argument initializer and may have multiple callers. | Plan audits all call sites and makes the group ID explicit at construction. |
| 3 | High | Local StoreKit group ID differs from the live group ID, so group-based local testing could fail. | Plan updates both local fixture group IDs while preserving the legacy group. |
| 4 | Medium | A UI test may be impractical because `SubscriptionStoreView` is StoreKit-runtime-backed. | Plan permits a focused configuration contract test plus compile/build verification rather than inventing a brittle snapshot test. |

**Round 1 result:** Re-review required for implementation-level call-site and fixture details.

### Round 2 — Re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | Medium | The `services.groupID!` force unwrap duplicates the guard and is safe only if the closure remains structurally under that guard. | Keep the existing guard and prefer binding `if let groupID = services.groupID` in the implementation so the invariant is explicit. |
| 2 | Medium | The fixture test must not assume a fragile JSON shape beyond the fields already present. | Decode only `subscriptionGroups`, each group `id`, and subscription `productID`; identify the Reader & Voice group by the voice product ID. |

| 3 | High | Settings has a second `SubscriptionsView()` call site outside the Library sheet. | Add Settings to the consumer audit and update it in the same change. |

**Round 2 result:** Re-review required because a High call-site gap was found.

### Round 3 — Re-review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | Medium | The two UI call sites have different surrounding guards and should not force-unwrap the optional. | Bind the optional with `if let groupID = services.groupID` in each existing guarded branch. |
| 2 | Medium | The implementation task originally named only Library, leaving Settings ambiguous. | Task 2 and the consumer audit now name both `LibraryTabView.swift` and `SettingsContent.swift`. |

**Round 3 result:** PASS for Critical/High issues; implementation must apply the Medium resolutions.

### Round 4 — Implementation review

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | High | A group-based paywall would still be incomplete if either live caller continued constructing the old zero-argument view. | Verified both Library and Settings pass the fetched group ID. |
| 2 | High | Local StoreKit fixtures could disagree with the worker/App Store Connect group and hide catalog-selection regressions. | Verified both Reader/Voice fixtures use `22247412` for the group and every Reader/Voice subscription. |
| 3 | Medium | Existing package and environment failures could be mistaken for regressions from this change. | Recorded focused-test and full-build failures as pre-existing/unrelated: stale billing test references and restricted package/cache/CoreSimulator access. |

**Round 4 result:** PASS with notes; 0 open Critical/High findings.

## Consumer / call-site audit

| Consumer | Current behavior | Required change |
|---|---|---|
| `LibraryTabView` paywall sheet | Checks `groupID != nil`, creates `SubscriptionsView()` | Bind `groupID` and pass `.value` |
| `SettingsContent` subscription section | Checks `groupID != nil`, creates `SubscriptionsView()` | Bind `groupID` and pass `.value` |
| `SubscriptionsView` | Explicit four-product `productIDs` initializer | Use `groupID` initializer |
| `CurrentViewModifier` | Uses fetched group ID for entitlement status lookup | No change |
| Worker `/api/groupID` | Returns `22247412` | No change |
| StoreKit product constants | Used by transaction/entitlement logic | Keep; no paywall catalog authority |

## Implementation order

1. Add the failing fixture contract test.
2. Update paywall call site and view initializer.
3. Align both local StoreKit fixtures.
4. Run focused tests and JSON validation.
5. Review the diff and run the Apple build/test gate.

## Explicitly out of scope

- App Store Connect API mutations or product-price changes.
- Worker endpoint creation or API authentication changes.
- Removing `RishiProductID.all` or entitlement product mappings.
- Changing the legacy Pro group.

# Cross-platform Apple subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add equivalent macOS/Catalyst Apple subscription products to the existing Reader & Voice group, show only the current platform’s plans, and grant one shared account entitlement across platforms.

**Architecture:** Keep the existing App Store Connect group and native StoreKit paywall, but replace the group-wide catalog assumption with an explicit platform catalog. Define iOS and macOS product IDs in one Swift source of truth and map both sets to the same Worker plan/entitlement map. Preserve the existing signed-in `appAccountToken` binding and canonical entitlement-sync path.

**Tech Stack:** SwiftUI, StoreKit 2, Mac Catalyst, Cloudflare Workers, TypeScript, Drizzle, Vitest, App Store Connect.

---

### Task 1: Verify live App Store Connect group and create macOS products

**Files:**
- Read: `apps/apple/docs/ASC-READER-VOICE-SUBSCRIPTIONS.md`
- Modify after live verification: `apps/apple/docs/ASC-READER-VOICE-SUBSCRIPTIONS.md`

- [ ] Confirm the live group is the existing Reader & Voice group, not the legacy Pro group.
- [ ] For each existing Reader/Voice plan, create one equivalent macOS product in that same group, using explicit IDs confirmed in App Store Connect (for example, a `.macos` suffix only if App Store Connect accepts and the user confirms that naming).
- [ ] Preserve Voice level 1 and Reader level 2, prices, duration, and plan semantics.
- [ ] Record the exact live product IDs and statuses in the ASC runbook.
- [ ] Confirm no second subscription group was created.

### Task 2: Add failing tests for platform product catalogs

**Files:**
- Modify: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/StoreKitConfigTests.swift`
- Create or modify: `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/RishiProductIDTests.swift`

- [ ] Add tests asserting the iOS and Catalyst product sets are disjoint, complete, and contain exactly the live product IDs.
- [ ] Add tests asserting each platform’s monthly and annual products map to the same Reader/Voice plan and duration.
- [ ] Run the focused Swift tests and confirm the new tests fail before implementation.

### Task 3: Implement platform-scoped product IDs and paywall loading

**Files:**
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Models/RishiProductID.swift`
- Modify: `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift`
- Modify: `apps/apple/rishi/rishi/rishi/Billing/SubscriptionsView.swift`
- Modify: `apps/apple/rishi/rishi/rishi/CurrentViewModifier.swift` only if the active warm-load path needs the same platform set

- [ ] Add explicit platform product sets and a platform-aware catalog accessor.
- [ ] Use `#if targetEnvironment(macCatalyst)` for Catalyst; do not treat Catalyst as native macOS.
- [ ] Ensure `Store.loadProducts()` requests only the current platform’s IDs.
- [ ] Change the visible paywall to use the explicit current-platform product IDs while retaining the existing app-account token, legal links, and entitlement checks.
- [ ] Do not expose legacy Pro products in the new Reader/Voice paywall.
- [ ] Run the focused Swift tests and confirm they pass.

### Task 4: Extend Worker product mapping to equivalent macOS products

**Files:**
- Modify: `workers/worker/src/billing/apple-product-plans.ts`
- Modify: `workers/worker/src/billing/entitlement-sync.ts` only if its validation assumes the old set
- Modify: `workers/worker/src/billing/apple-webhook.ts` only if webhook product validation is separately hard-coded
- Test: `workers/worker/src/billing/apple-product-plans.test.ts` or the existing entitlement-sync tests

- [ ] Add every verified macOS product ID to `APPLE_PRODUCT_PLAN_MAP` with the same plan and duration as its iOS counterpart.
- [ ] Keep product validation explicit; do not use a prefix wildcard.
- [ ] Add tests proving macOS transactions are accepted and produce the same allowance plan as iOS transactions.
- [ ] Add a cross-platform test proving the same signed-in user can sync one iOS transaction and one macOS transaction without either being rejected as an invalid product.
- [ ] Run the Worker’s focused Bun/Vitest tests.

### Task 5: Verify shared entitlement and prevent duplicate purchase presentation

**Files:**
- Inspect and modify only as required: `workers/worker/src/billing/apple-me.ts`, `workers/worker/src/billing/entitlement-sync.ts`, `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/CustomerEntitlements.swift`, `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/RestoreService.swift`
- Tests: corresponding existing Apple billing and entitlement tests

- [ ] Verify active entitlement reads are platform-neutral and keyed to the authenticated user, not the current product ID.
- [ ] Ensure current-entitlement replay and restore recognize both platform product families.
- [ ] Ensure the app does not show purchase options when the server/on-device entitlement already indicates an active subscription.
- [ ] If changing expiry handling, add a focused regression test so expired Apple rows cannot grant access.
- [ ] Run all focused Apple billing tests.

### Task 6: Independent adversarial review and verification

**Files:**
- Review all changed files and the live App Store Connect records.

- [ ] Review for Critical/High issues: second group creation, wrong platform products shown, missing Worker allow-list entries, cross-user replay, and duplicate billing.
- [ ] Fix every Critical/High finding and re-review until none remain.
- [ ] Run the Swift package/app tests relevant to RishiBilling and the Worker’s Bun tests.
- [ ] Verify the checked-in StoreKit configuration and ASC runbook agree with the live product IDs.
- [ ] Report any App Store Connect action that cannot be verified from the browser separately from code verification.

## Adversarial review section

- **Critical:** A second group would allow simultaneous subscriptions and duplicate charges. Verify the group identifier before and after product creation.
- **High:** `SubscriptionStoreView(groupID:)` can merchandise all products in the group. Prove the paywall receives only the current platform’s explicit products.
- **High:** A macOS product omitted from the Worker allow-list will fail after Apple purchase. Test every live macOS ID through entitlement sync.
- **High:** Product IDs mapped to the wrong plan can silently grant incorrect allowances. Test Reader and Voice mapping independently for monthly and annual products.
- **Medium:** Catalyst conditional compilation differs from native macOS. Confirm the project’s actual target and compile branch before selecting IDs.
- **Medium:** Existing subscribers may use legacy Pro products. Preserve their recognition while excluding them from the new paywall.

# App Review Remediation Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rishi Apple Release archive compliant with Apple’s reported 2.5.4, 5.1.1(iv), and 2.1(b) findings.

**Architecture:** Keep StoreKit 2 and the existing worker entitlement-sync contract. Centralize product-load state in the active `Store`, make `SubscriptionsView` consume that state with retry/restore recovery, remove the unsupported background-audio capability, and make microphone pre-prompts neutral.

**Tech Stack:** Swift 6, SwiftUI, StoreKit 2, AVFoundation, Xcode project tests, Cloudflare Worker TypeScript with Bun/Vitest.

---

## Scope and acceptance criteria

- The Release archive contains no `UIBackgroundModes` entry for `audio`.
- Neither custom microphone pre-prompt uses “Allow microphone”; both use “Continue” before the system prompt.
- A StoreKit product request failure, empty catalog, or partial catalog is visible and retryable; no purchase control is shown for missing products.
- The paywall requests the current platform’s four allow-listed products and uses the validated Reader/Voice subscription group/catalog.
- Restore is a user-visible action that walks current entitlements and refreshes the worker-backed entitlement state.
- The active Reader/Voice product IDs remain identical between app and worker; legacy products cannot grant a current entitlement accidentally.
- App Store Connect Sandbox/TestFlight confirms the actual storefront has the products available on the review device.
- Review metadata describes the actual Release archive, native Apple billing, and the real navigation path.

## File map

Apple app:

- Modify `apps/apple/rishi/rishi/Info.plist` to remove `audio` from `UIBackgroundModes`.
- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift` to expose typed catalog state and retry-safe loading.
- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift` to consume the injected catalog, show loading/unavailable states, wire restore, and retain native StoreKit policy links.
- Modify `apps/apple/rishi/rishi/Library/LibraryTabView.swift` and `apps/apple/rishi/rishi/Settings/SettingsContent.swift` to pass the validated subscription group ID into `SubscriptionsView`.
- Modify `apps/apple/rishi/rishi/CurrentViewModifier.swift` only where global StoreKit transaction observation or restore state is required.
- Modify `apps/apple/rishi/rishi/RootView.swift` to inject `Store.shared`, attach the single global `CustomerEntitlements` observer after the services and entitlement snapshot environments are applied, and update its `SubscriptionsView` call site.
- Create `apps/apple/rishi/rishi.xcodeproj/xcshareddata/xcschemes/rishi (Sandbox).xcscheme` with StoreKit Configuration set to `None` for real Sandbox/TestFlight validation.
- Modify `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/MicPermissionPrimer.swift` and `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/UI/VoicePermissionPrompt.swift` for neutral consent copy.
- Modify `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/OnboardingFlowView.swift` if denial is currently treated as completion without recording the decision.
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Permissions/SystemMicPermissionGate.swift` only if tests prove Settings recovery is not surfaced after denial.
- Add/update tests under `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/`, `apps/apple/rishi/rishiTests/PackageTests/RishiOnboarding/RishiOnboardingTests/`, and `apps/apple/rishi/rishiTests/PackageTests/RishiVoice/RishiVoiceTests/`.
- Modify `apps/apple/fastlane/metadata/en-US/description.txt`, `release_notes.txt`, and `review_information/notes.txt` to match the archive.
- Modify `apps/apple/docs/features/billing.md`, `apps/apple/docs/APP-STORE-METADATA.md`, and `apps/apple/docs/RUNBOOK-STOREKIT-SANDBOX.md` to remove stale external-billing and nonexistent-path instructions.

Worker:

- Review `workers/worker/src/billing/apple-product-plans.ts`, `entitlement-sync.ts`, and `apple-webhook.ts`.
- Modify worker files only if the compatibility/ownership tests below fail; no product or route rewrite is planned.
- Add/update tests in `workers/worker/src/billing/*.test.ts` using Bun/Vitest.

## Implementation order

1. Verify App Store Connect product/configuration facts and record the matrix.
2. Fix the active StoreKit catalog and paywall recovery path.
3. Fix restore/transaction observation and worker compatibility hazards.
4. Fix microphone consent copy and denial behavior.
5. Remove background audio metadata.
6. Align review metadata/docs.
7. Run exact-archive, device, and App Store Connect verification.

### Task 1: Establish the production StoreKit matrix

**Files:**

- Review `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/Models/RishiProductID.swift`
- Review `apps/apple/rishi/Rishi Reader.storekit`
- Review `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/Resources/Rishi.storekit`
- Review `workers/worker/src/billing/apple-product-plans.ts`
- Update `apps/apple/docs/RUNBOOK-STOREKIT-SANDBOX.md`

- [ ] In App Store Connect, verify bundle ID `org.fidexa.rishi`, Paid Apps Agreement, subscription group `rishi-reader-voice-group`, and the four iOS IDs: `rishi.reader.monthly`, `org.fidexa.rishi.reader.annual`, `org.fidexa.rishi.voice.monthly`, and `org.fidexa.rishi.voice.annual`.
- [ ] Verify each product is available in the App Review storefront, has an English localization, price, duration, and is attached to the submitted app version. Record exact values in the runbook.
- [ ] Compare the app allow-list, worker map, and both local fixtures. Keep iOS and `.macos` IDs platform-separated; do not let a local fixture override App Store Connect.
- [ ] Decide the legacy Pro policy. If grandfathered legacy transactions must remain valid, add an explicit compatibility map in `apple-product-plans.ts` and tests; otherwise remove legacy IDs from the active restore/sync path so `RestoreService` cannot repeatedly submit products the worker rejects.
- [ ] Add a test proving unknown and cross-platform IDs are rejected and the four current iOS IDs map to the intended plan/duration.

**Verification:** The runbook contains one authoritative matrix and a reviewer can compare it byte-for-byte with source, worker, fixtures, and App Store Connect.

### Task 2: Make active StoreKit loading observable and recoverable

**Files:**

- Modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/Store.swift`
- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`
- Modify `apps/apple/rishi/rishi/CurrentViewModifier.swift` if global loading/transaction state needs to move there
- Add/update tests in `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/`

- [ ] Replace the current `StoreError` single-case model with typed catalog errors that distinguish request failure, empty results, partial results, and invalid transaction while preserving existing error-observer behavior.
- [ ] Introduce an injectable product provider around `Product.products(for:)` and the subscription-group lookup used by production. The production provider must call StoreKit directly; tests must supply deterministic success, empty, partial, and failure responses.
- [ ] Make `Store.loadProducts()` clear stale products before a new request, request only `RishiProductID.currentPlatformProductIDs`, reject missing/partial responses, store the validated products/group ID, and publish a retryable error.
- [ ] Make `SubscriptionsView` observe `Store`’s loading/error/validated-products state. Show `ProgressView` during loading, a `ContentUnavailableView` with Retry for unavailable catalogs, and create the native StoreKit view only after all required products are present. On Retry, reload `Store` and reset the native view identity so StoreKit does not retain a failed blank state. Add a view-model/state test proving the native view is gated, not just a loader test.
- [ ] Inject the single `Store.shared` instance from `RootView` using SwiftUI’s environment and read it with `@Environment(Store.self)` in `SubscriptionsView`; do not pass a separate catalog snapshot. Retry must call that same injected instance and reset the native view identity.
- [ ] Keep ownership boundaries explicit: `Store` owns only StoreKit product/catalog state; `BootstrappedServices.groupID` from `GroupIDEndpoint` remains authoritative for subscription-status lookup. In `RootView.realBody(deps:)`, apply `.environment(\.services, deps.services)`, `.environment(deps.services!.entitlementSnapshotStore)`, and `.environment(Store.shared)` before `.checkCustomerEntitlements()`, then apply `.loadProducts()` and `.observeErrors()`. `SubscriptionsView` reads the catalog from `Store` and does not invent or fetch a second group ID.
- [ ] Keep `SubscriptionsView`’s initializer compatible with all existing callers, including `RootView`, `LibraryTabView`, and `SettingsContent`. Use the SDK-supported `SubscriptionStoreView(productIDs:)` initializer with the validated current-platform allow-list, not `groupID:`: this is the strict contract that prevents Catalyst IDs, legacy IDs, or any other group member from appearing in the iOS paywall. Continue using the fetched group ID only for `CustomerEntitlements` status lookup, validating it as non-empty/numeric in the root services path.
- [ ] Keep policy destinations on the canonical privacy and terms URLs and ensure the native UI displays dynamic price/period and auto-renewal disclosures.
- [ ] Add tests for success, request failure, empty response, partial response, retry clearing stale state, and iOS-vs-Catalyst product filtering.

**Verification:** A simulated StoreKit failure produces a visible Retry state; a complete catalog renders the native paywall; the wrong platform’s products are never requested or shown.

### Task 3: Wire restore and transaction observation to the active flow

**Files:**

- Modify `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`
- Modify `apps/apple/rishi/rishi/CurrentViewModifier.swift`
- Review/modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/RestoreService.swift`
- Review/modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/TransactionListener.swift`
- Review/modify `apps/apple/rishi/rishi/Modules/RishiBilling/RishiBilling/StoreKit/PurchaseService.swift`
- Add/update StoreKit tests in `apps/apple/rishi/rishiTests/PackageTests/RishiBilling/RishiBillingTests/StoreKit/`

- [ ] Replace the error-alert-only direct `AppStore.sync()` action with the injected `services.restoreService.restore()` flow, keeping restore user initiated. Surface `.restored`, `.nothingToRestore`, and failure states to the paywall.
- [ ] Preserve the existing `RestoreService` behavior that walks current entitlements and calls `syncEntitlement`; after completion refresh `entitlementSnapshotStore` so Settings and feature gates update immediately.
- [ ] Attach `checkCustomerEntitlements()` exactly once in `RootView.realBody(deps:)` after the `services` and `entitlementSnapshotStore` environment modifiers, remove `.checkCustomerEntitlements()` from `SubscriptionsView`, and keep `CustomerEntitlements` as the single transaction/status observer. Do not attach it in `rishiApp` and do not also start the unused `TransactionListener`. Add an idempotence test for startup and a transaction-update test while the paywall is absent.
- [ ] Preserve the rule that transactions are finished only after successful entitlement synchronization.
- [ ] Add tests for restore success, no matching entitlement, sync failure, and transaction updates arriving while the paywall is not presented.

**Verification:** The Restore Purchases control executes the real restore service; a restored subscription updates the same entitlement state used by Settings and feature gates.

### Task 4: Harden the worker boundary only where the audit requires it

**Files:**

- Review/modify `workers/worker/src/billing/apple-product-plans.ts`
- Review/modify `workers/worker/src/billing/entitlement-sync.ts`
- Review/modify `workers/worker/src/billing/apple-webhook.ts`
- Review/update `workers/worker/src/db/schema.ts` only if ownership persistence requires a schema-safe change
- Add/update `workers/worker/src/billing/apple-product-plans.test.ts`, `apple-webhook.test.ts`, `apple-me.test.ts`, and `jws-verify.test.ts`

- [ ] Add a test that the active four iOS product IDs, their `.macos` counterparts, and any deliberately supported legacy IDs map explicitly to the correct plan; reject everything else.
- [ ] Resolve the webhook pre-verification ownership path with this concrete rule: when `findUserIdByOriginalTransactionId()` returns `null`, log the verified notification and do not call `upsertSub`; add a test asserting zero subscription writes and a later ownership-reconciliation test. If schema changes are required for reconciliation, use Drizzle schema/migrations and preserve existing rows.
- [ ] Remove or quarantine the stale app call to `/auth/verify-transaction` if it is not part of the active flow; do not add a redundant worker route just to preserve dead client code.
- [ ] Update the drifted worker tests with the current ledger and `app_account_token` fixtures so the focused Apple billing test suite is green.

**Verification:** From `workers/worker`, `bun test src/billing/apple-product-plans.test.ts src/billing/apple-webhook.test.ts src/billing/apple-me.test.ts src/billing/jws-verify.test.ts` passes; if worker source/schema changes, also run the package’s existing type-check script. No raw SQL is added to worker application/test code.

### Task 5: Correct microphone consent UX and denial recovery

**Files:**

- Modify `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/MicPermissionPrimer.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/UI/VoicePermissionPrompt.swift`
- Modify `apps/apple/rishi/rishi/Modules/RishiOnboarding/RishiOnboarding/UI/OnboardingFlowView.swift` if needed
- Review `apps/apple/rishi/rishi/Onboarding/OnboardingHost.swift` and `apps/apple/rishi/rishi/Modules/RishiVoice/RishiVoice/Permissions/SystemMicPermissionGate.swift`
- Add/update `MicPermissionGateTests.swift` and onboarding/voice UI tests

- [ ] Change both custom pre-prompt buttons from `Allow microphone` to `Continue`; the callback remains the point that invokes `AVAudioApplication.requestRecordPermission()`.
- [ ] Use one accurate rationale: microphone audio is used for active voice conversations and is not captured by an idle onboarding screen. Keep the system `NSMicrophoneUsageDescription` semantically aligned.
- [ ] Preserve `Not now` as a non-destructive choice that completes onboarding without blocking reading.
- [ ] Ensure a later voice-chat attempt after denial shows the existing Settings recovery message rather than silently failing or repeatedly asking.
- [ ] Add tests for fresh request, granted, denied, previously denied, Settings recovery, and the exact absence of the forbidden button label.

**Verification:** On a clean install, tapping Continue leads to Apple’s system dialog; tapping Not now leaves the app usable; denied users receive actionable Settings guidance when voice is attempted.

### Task 6: Remove unsupported background-audio capability

**Files:**

- Modify `apps/apple/rishi/rishi/Info.plist`
- Review `apps/apple/rishi/rishi/rishiApp.swift`, `AudioSessionCoordinator.swift`, and `WebRTCConnector.swift` for claims or behavior that require background audio
- Update `apps/apple/fastlane/metadata/en-US/release_notes.txt` and `apps/apple/fastlane/metadata/review_information/notes.txt`
- Add/update archive metadata validation if one exists

- [ ] Remove the `audio` value from `UIBackgroundModes`; keep only background modes used by an independently verified feature.
- [ ] Create the shared `rishi (Sandbox).xcscheme`, set Run → Options → StoreKit Configuration to `None`, and verify `xcodebuild -list` reports it before real Sandbox validation.
- [ ] Confirm voice sessions are still ended on background and foreground Read Aloud remains functional; do not add a new background playback feature in this remediation.
- [ ] Remove any metadata or review-note claim that Rishi provides persistent background audio.
- [ ] Add a Release-archive check that fails if `UIBackgroundModes` contains `audio`.

**Verification:** `plutil -p apps/apple/build/Rishi.xcarchive/Products/Applications/rishi.app/Info.plist` shows no `audio` background mode, and foreground Read Aloud still passes its existing tests.

### Task 7: Align App Store metadata and review instructions

**Files:**

- Modify `apps/apple/fastlane/metadata/en-US/description.txt`
- Modify `apps/apple/fastlane/metadata/en-US/release_notes.txt`
- Modify `apps/apple/fastlane/metadata/review_information/notes.txt`
- Modify `apps/apple/docs/APP-STORE-METADATA.md`
- Modify `apps/apple/docs/RUNBOOK-STOREKIT-SANDBOX.md`
- Update `apps/apple/fastlane/scripts/validate_metadata.rb` if validation exists for these claims

- [ ] Remove claims that subscriptions are managed or purchased at `rishi.fidexa.org`; retain only legally required links and native Apple manage-subscription instructions.
- [ ] Remove DEBUG-only, Developer Bypass, and “no IAP UI” instructions from review notes.
- [ ] Document exact Release navigation: sign in, open a Pro-gated feature, wait for the paywall catalog, purchase/restore, open voice permission, and use foreground Read Aloud.
- [ ] Ensure the notes explicitly say the app does not require background audio and that the submitted binary has no `audio` mode.
- [ ] Update docs to reference the active `apps/apple/rishi/rishi/...` paths and create/use a clear StoreKit Sandbox/TestFlight validation procedure without claiming a nonexistent scheme.
- [ ] Run the anti-steering metadata check and fail on website purchase language, placeholder review credentials, or stale DEBUG instructions.

**Verification:** App Store metadata, review notes, and the Release binary describe the same purchase, permission, and audio behavior.

### Task 8: Run the exact release validation gate

**Files:**

- Review all changed Apple/worker files
- Create build artifacts only under `apps/apple/build/` or another explicitly scoped ignored directory

- [ ] Run the Apple project tests against an available simulator, using the discovered `iPad Air 11-inch (M4)` destination when present:

```bash
xcodebuild -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' test CODE_SIGNING_ALLOWED=NO
```

- [ ] Run focused worker tests with Bun from `workers/worker`:

```bash
cd workers/worker
bun test src/billing/apple-product-plans.test.ts src/billing/apple-webhook.test.ts src/billing/apple-me.test.ts src/billing/jws-verify.test.ts
```

- [ ] Build the submitted archive:

```bash
xcodebuild -project apps/apple/rishi/rishi.xcodeproj -scheme rishi -configuration Release -destination 'generic/platform=iOS' archive -archivePath apps/apple/build/Rishi.xcarchive
```

- [ ] Inspect the generated archive:

```bash
plutil -p apps/apple/build/Rishi.xcarchive/Products/Applications/rishi.app/Info.plist
codesign -d --entitlements :- apps/apple/build/Rishi.xcarchive/Products/Applications/rishi.app
```

- [ ] On a clean physical iPad/iPhone or TestFlight build, verify fresh install, sign-in, paywall load, purchase, restore, denied microphone, Settings recovery, and foreground Read Aloud.
- [ ] In App Store Connect Sandbox/TestFlight, verify the exact four iOS products load in the reviewer storefront; do not rely solely on `Rishi Reader.storekit`.
- [ ] Upload the exact archive and metadata only after all stop conditions pass.

**Stop conditions:** Do not resubmit if products are unavailable in App Store Connect, the paywall can be blank with no retry, either pre-prompt says “Allow microphone,” the archive contains `audio`, review notes require DEBUG access, or the worker rejects a valid current-platform transaction.

## Consumer / call-site audit

| Change | Consumers to verify |
|---|---|
| StoreKit catalog/error state | `Store.swift`, `SubscriptionsView.swift`, `RootView.swift`, `CurrentViewModifier.swift`, `LibraryTabView.swift`, `SettingsContent.swift`, `ServiceGraphFactory.swift` |
| Restore/transaction updates | `RestoreService.swift`, `TransactionListener.swift`, `CustomerEntitlements.swift`, `CurrentViewModifier.swift`, feature gates |
| Product identity | `RishiProductID.swift`, `Rishi Reader.storekit`, test fixture, `apple-product-plans.ts`, `entitlement-sync.ts`, webhook handlers |
| Microphone copy/decision | `MicPermissionPrimer.swift`, `VoicePermissionPrompt.swift`, `OnboardingFlowView.swift`, `OnboardingHost.swift`, `SystemMicPermissionGate.swift`, generated `NSMicrophoneUsageDescription` |
| Background audio | `Info.plist`, `rishiApp.swift`, `AudioSessionCoordinator.swift`, `WebRTCConnector.swift`, release metadata |
| Review instructions | description, release notes, review notes, metadata validator, Sandbox/TestFlight runbook |

## Explicitly out of scope

- Persistent background playback implementation or a screen-recording appeal for background audio.
- Replacing StoreKit, AVFoundation, WebRTC, or the existing worker entitlement architecture.
- Adding new product IDs, subscription groups, price points, trials, or entitlement economics.
- Website-managed subscription purchase or external-link billing.
- Broad cleanup unrelated to the three rejection findings.

## Adversarial review loop

Each round: review the current plan against the repository, log findings, update the plan, then re-review the updated plan.

### Round 1 — Research review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Critical | The active paywall uses `SubscriptionStoreView(productIDs:)` while the shared StoreKit loader hides request failures, matching the reviewer’s blank/unavailable result. | Task 2 makes the active loader injectable, typed, visible, and retryable; Task 8 tests the real storefront. |
| 2 | High | Restore is only an error-alert `AppStore.sync()` action and does not invoke the production restore service. | Task 3 wires the user-facing restore action through `RestoreService` and entitlement refresh. |
| 3 | High | The separate `TransactionListener` has no production construction call site; the app instead has a global `CustomerEntitlements` observer whose ownership must be explicit and idempotent. | Task 3 keeps one global observer owner, avoids duplicate listeners, and tests updates while the paywall is closed. |
| 4 | High | Both custom microphone prompts say `Allow microphone`, directly matching Apple’s 5.1.1 finding. | Task 5 changes both to `Continue` and tests the exact copy. |
| 5 | High | `UIBackgroundModes=audio` is present without reviewer evidence, and the user wants the compliant path. | Task 6 removes it instead of trying to justify unsupported persistence. |
| 6 | Critical | Metadata says subscriptions are managed on the website and review notes deny native IAP/require DEBUG, contradicting the shipped binary. | Task 7 rewrites metadata and notes from the actual Release flow and runs anti-steering validation. |
| 7 | High | Worker source already matches current Reader/Voice IDs, but legacy IDs and webhook empty-string ownership can break restore or webhook processing. | Task 1 makes legacy policy explicit; Task 4 tests and fixes only those concrete compatibility hazards. |
| 8 | Medium | Existing documentation references stale package paths and a nonexistent Sandbox scheme. | Task 7 updates docs from `xcodebuild -list` and active paths. |

**Round 1 result:** Re-review required; all Critical/High findings have explicit task/file/test resolutions.

### Round 2 — Plan re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A plan that only changes UI copy could still leave the reviewer-visible subscription failure because production uses a different loader than the tested service. | Task 2 names `Store.swift` as the production authority and requires provider-backed tests against it. |
| 2 | High | Using a hard-coded group or product list could reintroduce the cross-platform catalog problem. | Tasks 1–2 require explicit platform allow-lists, validated group/catalog state, and cross-platform tests. |
| 3 | High | Direct `AppStore.sync()` can show an unexpected Apple sign-in prompt and does not reconcile the worker entitlement. | Task 3 requires user-initiated restore-service behavior and post-restore entitlement refresh. |
| 4 | High | Removing `audio` from source without inspecting the archive could leave generated Release settings or metadata inconsistent. | Tasks 6 and 8 require archive-level `plutil` inspection and metadata checks. |
| 5 | High | Worker changes could violate the repository’s Drizzle-only database rule. | Task 4 explicitly requires Drizzle schema/migrations and forbids raw SQL in worker app/tests. |

**Round 2 result:** Re-review required. The independent reviewer found missing paywall state bridging, omitted paywall call sites, an underspecified restore action, an inaccurate observer diagnosis, a concrete webhook empty-owner write, an invalid worker test suggestion, and an uncreated Sandbox scheme. These are corrected below.

### Round 3 — Re-review after corrections

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | A validated `Store` catalog would not prevent `SubscriptionStoreView(productIDs:)` from independently loading a blank catalog. | Task 2 now requires `SubscriptionsView` to observe catalog state, gate native view creation, reset identity on retry, and test the bridge. |
| 2 | High | `LibraryTabView` and `SettingsContent` discarded the validated group ID and were absent from the StoreKit task. | The file map and Task 2 now name both call sites and require `SubscriptionsView(groupID:)` with numeric validation. |
| 3 | High | Webhook code could still call `upsertSub` with an empty owner before device verification. | Task 4 now requires no subscription write when ownership is unknown and tests later reconciliation explicitly. |
| 4 | Medium | Restore was described as if `RestoreService` lacked entitlement-sync behavior, while the actual defect is the alert action bypassing it. | Task 3 now preserves the existing service and specifies the app-level action, result states, and snapshot refresh. |
| 5 | Medium | The plan overstated paywall-scoped observation because `CustomerEntitlements` is already started globally. | Task 3 now names one global observer owner and avoids wiring the unused duplicate listener. |
| 6 | Medium | The worker command used a nonexistent `bun run test` script. | Task 4 and Task 8 now use `cd workers/worker && bun test ...`. |
| 7 | Medium | The plan referenced a Sandbox scheme without creating it. | Task 6 and Task 8 now create it, set StoreKit Configuration to `None`, and verify it with `xcodebuild -list`. |

**Round 3 result:** Re-review required. The independent reviewer found an unlisted `RootView` paywall call site, an incorrect claim that entitlement observation was already global, an underspecified Store-to-view state bridge, and an ambiguous group-paywall product-display contract. These are corrected below.

### Round 4 — Re-review after ownership and filtering corrections

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | High | `RootView.swift` also constructs `SubscriptionsView()`, so changing its dependencies without naming that call site could break compilation. | The file map and Task 2 now name `RootView` and require the initializer to remain compatible with all callers. |
| 2 | High | `CustomerEntitlements` observation currently begins only inside `SubscriptionsView`, not globally. | Task 3 now explicitly attaches the modifier once at `RootView`/`rishiApp` and removes it from the paywall. |
| 3 | Medium | The Store-to-paywall bridge did not identify the owner of the observed catalog. | Task 2 now specifies `Store.shared` injected via SwiftUI environment and retry against that same instance; no separate snapshot is passed. |
| 4 | Medium | A group-based paywall could merchandise products outside the current platform allow-list. | Task 2 now selects strict `SubscriptionStoreView(productIDs:)` after validated catalog filtering and reserves group ID for status lookup. |

**Round 4 result:** Re-review required. The independent reviewer found an unsafe `RootView`/`rishiApp` alternative, one inconsistent archive path, and an unclear Store-vs-service group-ID owner. These are corrected below.

### Round 5 — Final re-review

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | Attaching the observer in `rishiApp` would lack the services environment needed for status reconciliation. | Task 3 now requires the observer only in `RootView.realBody(deps:)`, after services and snapshot environments, with exact modifier order. |
| 2 | Medium | One verification path used `build/Rishi.xcarchive` while the archive command writes `apps/apple/build/Rishi.xcarchive`. | Task 6 now uses the exact archive path consistently. |
| 3 | Medium | StoreKit catalog ownership and worker group-ID ownership were not separated explicitly. | Task 2 now states that `Store` owns product state while `BootstrappedServices.groupID` from `GroupIDEndpoint` remains authoritative for status lookup. |

**Round 5 result:** PASS — 0 open Critical/High or unresolved Medium issues. Remaining manual dependencies are explicit submission gates: App Store Connect product availability, Paid Apps Agreement, privacy-policy accuracy, and physical-device/TestFlight behavior.

## Final verification status

The current app build is clean on the available `iPad Air 11-inch (M4)` simulator destination (`xcodebuild ... build`, exit 0). The requested `iPhone 16` destination is unavailable locally; the plan uses an installed iPad destination for the test gate. Worker audit found existing test drift, so focused Bun tests are mandatory before claiming the worker boundary is green.

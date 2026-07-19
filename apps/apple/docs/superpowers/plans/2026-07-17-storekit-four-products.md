# StoreKit four products, appAccountToken, and entitlement sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Testing note:** This plan deliberately contains NO test-writing steps, per explicit user override. Every step is "implement the real code" followed by "verify with `swift build` / `swift test --package-path` / `xcrun --sdk iphonesimulator swiftc -typecheck`," never "write a failing test." Existing tests (`PurchaseServiceTests`, `RestoreServiceTests`, `PaywallOnSubscribeWiringTests`, `TransactionListenerTests`) must keep compiling and passing — this plan is written to avoid breaking any of their call sites (see Task 5's signature-compatibility note).
>
> **Build-clean precondition (`apps/apple/CLAUDE.md`):** before starting, and again before declaring any task done, confirm the touched package still builds. Do NOT invoke `xcodebuild rishi` (600s watchdog risk). Use `swift test --package-path apps/apple/Packages/RishiBilling` / `swift test --package-path apps/apple/Packages/RishiCore` and `xcrun --sdk iphonesimulator swiftc -typecheck <file>` for app-target files under `apps/apple/rishi/`.

**Goal:** Define the four new Reader/Voice StoreKit product IDs (added alongside, not replacing, the two legacy Pro IDs), add them to both local `.storekit` test configs, implement a Swift `AppAccountToken.derive(userId:)` that is byte-identical to the Worker's UUID v5 algorithm, wire that token into every live purchase path (the `PurchaseService` actor and the `SubscriptionStoreView`-based paywall), and — after every verified purchase, restore, and StoreKit transaction update — POST the transaction's signed JWS to the new `POST /api/billing/entitlement-sync` route so the Worker becomes aware of the entitlement. This is plan 11 of 16; it does **not** touch allowance UI, the Reader/Voice tier split in `EntitlementLevel`, subscriber grandfathering, or consuming the sync response body (`EntitlementSnapshot`) — those are later plans' scope, called out explicitly below.

**Architecture:** One new shared product-ID constants file (`RishiProductID`) so `Store.fetchProductIDs()` and `EntitlementLevel.initialize(productId:)` cannot drift apart. One new `AppAccountToken` type (UUID v5 derivation + a `currentPurchaseOptions()` helper that reads the session from `KeychainSessionStore`). One new `WorkerEndpointWithBody` conformer (`EntitlementSyncEndpoint`, in `RishiCore`, following `VerifyReceiptEndpoint`'s shape) plus one new DI-friendly actor (`EntitlementSyncClient`, in `RishiBilling`, following `WorkerReceiptVerifier`'s shape) for `PurchaseService` to depend on. For the three bare singletons that have no DI graph today (`Store`, `CustomerEntitlements`, `RestoreService`), a small internal fire-and-forget free function calls the same endpoint directly via the existing `WorkerEndpoint.send()` extension — mirroring the `VerifyEndPont(...).send()` call already present in `CustomerEntitlements.swift`, rather than inventing DI for singletons that don't have any.

**Tech Stack:** Swift 6 strict concurrency, StoreKit 2 (`Product.PurchaseOption`, `VerificationResult.jwsRepresentation`, `SubscriptionStoreView.inAppPurchaseOptions(_:)`), CryptoKit (`Insecure.SHA1`, iOS 13+, no new SPM dependency), the existing `WorkerEndpoint`/`WorkerClient` networking stack in `RishiCore`.

---

## Context you must know before starting

### 1. `SubscriptionStoreView` cannot carry `appAccountToken` through its automatic purchase flow — use `.inAppPurchaseOptions(_:)`, not a `PurchaseAction` override

Apple's own `purchase(options:)` documentation states: *"If you use StoreKit views such as `ProductView`, `StoreView`, or `SubscriptionStoreView` you don't need to call any other API to initiate a purchase. StoreKit manages the purchase action automatically."* There is no supported way to intercept `SubscriptionStoreView`'s internal purchase call via the `\.purchase` (`PurchaseAction`) environment value — that environment value is for *custom* buy buttons built from scratch, not for overriding a StoreKit view's own automatic action.

The correct, documented mechanism (confirmed via Apple's `inAppPurchaseOptions(_:)` reference and the design doc's own instruction — *"Use a Rishi-controlled StoreKit purchase action rather than an opaque purchase view when necessary to pass `appAccountToken`"*) is the view modifier:

```swift
nonisolated func inAppPurchaseOptions(_ options: ((Product) async -> Set<Product.PurchaseOption>)?) -> some View
```

Attached anywhere above a `SubscriptionStoreView`/`StoreView`/`ProductView` in the view hierarchy, StoreKit calls this closure immediately before starting any purchase from a descendant StoreKit view and merges the returned options into that purchase. This is a one-line addition to `SubscriptionsView.swift` (Task 6) — no paywall UI rewrite, no `ProductView`/manual-button replacement of `SubscriptionStoreView` needed.

### 2. `VerificationResult<Transaction>.jwsRepresentation` is a native StoreKit 2 property — no custom extension needed

Confirmed via Apple documentation: `jwsRepresentation` is declared directly on `VerificationResult<Transaction>` (available iOS 15+), returning the raw signed JWS `String` regardless of whether the case is `.verified` or `.unverified`. Every call site below reads it straight off the `VerificationResult` value it already has in scope, before or instead of unwrapping to the plain `Transaction`.

### 3. Exact product IDs, tiers, and prices (from the design doc's pricing table and "Subscription transitions" section)

| Product ID | Tier | `groupNumber` | Duration | Price |
| --- | --- | --- | --- | --- |
| `org.fidexa.rishi.voice.monthly` | Voice (level 1 — higher) | 1 | 1 month | $14.99 |
| `org.fidexa.rishi.voice.annual` | Voice (level 1 — higher) | 1 | 1 year | $143.99 |
| `org.fidexa.rishi.reader.monthly` | Reader (level 2 — lower) | 2 | 1 month | $7.99 |
| `org.fidexa.rishi.reader.annual` | Reader (level 2 — lower) | 2 | 1 year | $76.99 |

All four go in **one new** StoreKit subscription group (not the existing "Rishi Pro" group), matching the design doc: *"Place all four products in one StoreKit subscription group. Voice monthly and yearly products are level 1; Reader monthly and yearly products are level 2."* `groupNumber` is StoreKit's within-group **level** field (lower number = higher tier) — confirmed by reading the existing `Rishi Reader.storekit`, where `.pro.monthly` and `.pro.annual` (the same tier, just different durations) both carry `groupNumber: 1`. The sibling worker plan (`2026-07-17-storekit-entitlement-sync.md`) independently locked these same four identifiers — this plan's IDs are byte-identical to that plan's `APPLE_PRODUCT_PLAN_MAP` keys.

**Pre-existing bug found while reading the test fixture, fixed as part of this plan (not a drive-by — it directly affects the products this plan adds):** `Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit`'s existing Pro group has `groupNumber: 1` for monthly and `groupNumber: 2` for annual — i.e. the SAME tier accidentally split across two levels. Task 2 does **not** touch that existing (buggy but out-of-scope) group; it only ensures the NEW group this plan adds does not repeat that mistake (Voice monthly+annual both `1`, Reader monthly+annual both `2`).

### 4. `appAccountToken` derivation — copied byte-for-byte from the Worker's already-landed implementation

`workers/worker/src/billing/entitlement-sync.ts`'s `deriveAppAccountToken` (already implemented and reviewed in the sibling plan `2026-07-17-storekit-entitlement-sync.md`) is:

```typescript
const APP_ACCOUNT_TOKEN_NAMESPACE = "fbf6524d-646b-4317-b479-476821e250f6";
// UUID v5 = SHA-1(namespaceBytes ++ utf8Bytes(userId)), truncate to 16
// bytes, hash[6] = (hash[6] & 0x0f) | 0x50 (version), hash[8] = (hash[8] &
// 0x3f) | 0x80 (variant), format 8-4-4-4-12.
```

`userId` is the Worker's Rishi `user.id` — Better Auth's default `generateId()`, a **32-character alphanumeric string, NOT a UUID** (confirmed by the sibling plan reading `@better-auth/core/src/utils/id.ts` directly). It is exposed to the iOS app as `Session.userId` (`RishiCore/Models/Session.swift`, persisted by `KeychainSessionStore`) — **not** `RishiCore`'s local `UserID`/`DerivedUserID` types, which are unrelated UUID-shaped local-storage keys used elsewhere in the app (`RootView.swift`'s `deps.setUserId(uuidUserId)` path parses a *different*, locally-scoped identifier and must not be confused with this one).

Task 3 implements this in Swift using `CryptoKit.Insecure.SHA1` (available iOS 13+, well below this package's iOS 18 minimum — no new SPM dependency, no Package.swift edit).

### 5. Entitlement-sync route contract (already landed server-side; this plan only calls it)

`POST /api/billing/entitlement-sync`, behind `requireAuth` (Bearer token — same `WorkerClient` auth chain as every other endpoint). Request:

```json
{ "transactionJWS": "<VerificationResult.jwsRepresentation>" }
```

Response (always HTTP 200 except a malformed-body 400):

```typescript
interface EntitlementSyncResponse {
  verified: boolean;
  reason: string | null;
  snapshot: EntitlementSnapshot | null; // 5-state union — see note below
}
```

**This plan's `EntitlementSyncEndpoint.ResponseBody` deliberately does NOT decode `snapshot` into a typed `EntitlementSnapshot`.** That union type and its caching/consumption is the separate, not-yet-written "entitlement-snapshot-client" plan's job (it already owns `/api/billing/me`'s response for the same reason). Decoding only `verified`/`reason` here is not a shortcut — it avoids this plan guessing at, and potentially duplicating or drifting from, a type that plan will define authoritatively. `Decodable`'s default behavior ignores the unknown `snapshot` key, so this is forward-compatible with no code change needed once that plan lands and wants to add its own decode of the same response elsewhere.

### 6. `PurchaseService` is real but not wired into the app's DI graph — `Store`/`CustomerEntitlements`/`RestoreService` are the live path

Confirmed by reading `ServiceGraphFactory.swift`: it constructs `WorkerReceiptVerifier` and `RestoreService`, but never constructs a `PurchaseService`, and `StoreKitProductService` (the `ProductFetching` implementation `PurchaseService` would need) is fully commented out elsewhere. The actually-live purchase path is `RootView.swift`'s `.onInAppPurchaseCompletion` → `Store.shared.process(purchaseResult:)` → `CustomerEntitlements.shared.process(transaction:)`, plus `SubscriptionsView.swift`'s `SubscriptionStoreView` (which is what actually renders the paywall and triggers purchases the app-wide completion handler observes) and `CurrentViewModifier.swift`'s `checkCustomerEntitlements()` (which drives `CustomerEntitlements.shared.observeTransactionUpdates()` / `checkForCurrentEntitlements()` / `checkForUnfinishedTransactions()`).

This plan updates **both** paths per the task brief's explicit instruction, but treats them differently: the live singletons get the minimal fire-and-forget free-function call (Context item 7 below); `PurchaseService` gets a proper injected dependency (Task 5) so it stays testable and ready for whichever future plan wires it into `ServiceGraphFactory`.

### 7. No existing DI graph for `Store` / `CustomerEntitlements` / `RestoreService` — don't invent one for this plan

All three are bare `public static let shared: X = .init()` singletons with zero constructor parameters. `CustomerEntitlements.swift` already calls a Worker endpoint directly and synchronously-fires-a-request via `try await VerifyEndPont(body: .init(transactionId: transaction.id)).send()` — the `WorkerEndpoint.send()` extension builds its own throwaway `WorkerClient` from `KeychainSessionStore` + `RishiAuthTokenProvider` + the `RISHI_API_URL` env var every time it's called. This plan's new fire-and-forget helper (Task 7's `EntitlementSyncFireAndForget.swift`) follows that exact existing precedent instead of retrofitting constructor-injected dependencies onto three singletons that don't have any today — that retrofit would be a much larger, out-of-scope change (every `.shared` call site across the app would need updating).

### 8. App-lifecycle sync hook — DECISION: flagged as a follow-up, not built here

The design doc requires sync "at launch, foreground, purchase completion, restore, and StoreKit transaction updates." Searching the app target confirms:
- No `scenePhase`/`didBecomeActive` observation exists anywhere (`rishiApp.swift` has none).
- `RestoreService.refreshOnDeviceEntitlementAtLaunch()` — a method that already exists, named for exactly this purpose — is **dead code today**: defined but called from nowhere in the app target.
- `CustomerEntitlements.shared.checkForCurrentEntitlements()` / `.observeTransactionUpdates()` only run when `SubscriptionsView` (the paywall screen) appears (`CurrentViewModifier.swift`'s `.checkCustomerEntitlements()`), not at true app launch or foreground.

Per the task brief's explicit instruction not to build new launch/foreground lifecycle wiring in this plan: **this plan does not add a `scenePhase` observer or call `refreshOnDeviceEntitlementAtLaunch()` from anywhere new.** It implements the sync call as a reusable function/endpoint (Tasks 4/7) and wires it only into the paths that already run today — purchase completion (`Store.process`/`CustomerEntitlements.process`), the paywall-screen-appearance entitlement checks (`checkForCurrentEntitlements`/`checkForUnfinishedTransactions`/`observeTransactionUpdates`, all inside `CustomerEntitlements.swift`), and restore (`RestoreService.restore()` and, for free, `refreshOnDeviceEntitlementAtLaunch()` once some future plan finally calls it). **A true app-wide launch/foreground hook remains a small, explicit follow-up** — see "Exports for downstream plans" at the bottom; the "entitlement-snapshot-client" plan, which the task brief says may want to fetch `/api/billing/me` at the same lifecycle points, is the natural place to add one `scenePhase` observer that calls both that plan's fetch AND this plan's sync helpers together, rather than two plans each adding their own separate hook.

### 9. `RestoreService`'s existing product-id filter would silently exclude all four new products — fixed in Task 9

`RestoreService.readActiveProductIds()` filters `Transaction.currentEntitlements` with `tx.productID.hasPrefix(Self.productIdPrefix)`, where `productIdPrefix = "org.fidexa.rishi.pro."`. The four new IDs (`org.fidexa.rishi.reader.*` / `org.fidexa.rishi.voice.*`) do not share that prefix, so restore would silently drop them today. Task 9 replaces the prefix check with `EntitlementLevel.initialize(productId:) == .subscribed` (which Task 1 updates to recognize all six IDs) — the single source of truth for "is this one of Rishi's known subscription products," instead of a second, driftable prefix string.

---

## File structure

- **Create:** `Packages/RishiBilling/Sources/RishiBilling/Models/RishiProductID.swift` — the six product ID constants (2 legacy + 4 new), single source of truth for `Store.fetchProductIDs()` and `EntitlementLevel.initialize`.
- **Create:** `Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppAccountToken.swift` — `derive(userId:) -> UUID` + `currentPurchaseOptions() -> Set<Product.PurchaseOption>`.
- **Create:** `Packages/RishiCore/Sources/RishiCore/Endpoints/EntitlementSyncEndpoint.swift` — the typed Worker endpoint.
- **Create:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncClient.swift` — `EntitlementSyncing` protocol + production `EntitlementSyncClient` actor, for `PurchaseService`'s DI.
- **Create:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncFireAndForget.swift` — the internal free function `Store`/`CustomerEntitlements`/`RestoreService` call directly.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/Models/EntitlementLevel.swift` — recognize all six product IDs.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/Store.swift` — `fetchProductIDs()` uses `RishiProductID.all`; `process(purchaseResult:)` forwards the JWS.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/CustomerEntitlements.swift` — `process(transaction:jws:)` + four call sites + fire-and-forget sync.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/RestoreService.swift` — fixed product filter + fire-and-forget sync per restored transaction.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/StoreKit/PurchaseService.swift` — inject `EntitlementSyncing`, pass `appAccountToken` on the default purchase closure, sync after every StoreKit-verified transaction.
- **Modify:** `apps/apple/rishi/Rishi Reader.storekit` — new subscription group with the four new products (v5 schema).
- **Modify:** `Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit` — new subscription group with the four new products (v4 schema).
- **Modify:** `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift` — add `.inAppPurchaseOptions(_:)`.
- **Modify:** `Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift` — document the new public symbols.

---

### Task 1: Product ID constants (single source of truth)

**Files:**
- Create: `Packages/RishiBilling/Sources/RishiBilling/Models/RishiProductID.swift`
- Modify: `Packages/RishiBilling/Sources/RishiBilling/Models/EntitlementLevel.swift`
- Modify: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/Store.swift`

- [ ] **Step 1: Create the constants file**

```swift
import Foundation

/// Every Apple product ID Rishi's StoreKit configuration defines, across
/// the legacy 2-product "Pro" tier and the new 4-product Reader/Voice tier
/// (2026-07-17 pricing/trial-launch design doc). Single source of truth for
/// ``Store/fetchProductIDs()`` and ``EntitlementLevel/initialize(productId:)``
/// so the two lists cannot silently drift apart.
///
/// **Decision — ADD, do not replace:** the legacy `.pro.monthly` /
/// `.pro.annual` ids are kept alongside the four new ones. Existing
/// subscribers on the old "Pro" tier must keep a valid, still-fetchable
/// product id and a `.subscribed` ``EntitlementLevel`` until a dedicated
/// grandfathering/migration plan decides how (or whether) to move them onto
/// Reader/Voice — deciding that is explicitly OUT OF SCOPE here. Removing
/// these two ids would silently break `Product.products(for:)` and
/// `EntitlementLevel.initialize` for anyone still on Pro.
public enum RishiProductID {
    public static let proMonthly = "org.fidexa.rishi.pro.monthly"
    public static let proAnnual = "org.fidexa.rishi.pro.annual"

    public static let readerMonthly = "org.fidexa.rishi.reader.monthly"
    public static let readerAnnual = "org.fidexa.rishi.reader.annual"
    public static let voiceMonthly = "org.fidexa.rishi.voice.monthly"
    public static let voiceAnnual = "org.fidexa.rishi.voice.annual"

    /// All six ids Rishi currently defines in StoreKit / App Store Connect.
    /// `Store.fetchProductIDs()` requests exactly this list.
    public static let all: [String] = [
        proMonthly, proAnnual,
        readerMonthly, readerAnnual,
        voiceMonthly, voiceAnnual,
    ]

    /// The four new Reader/Voice ids only, excluding legacy Pro. No caller
    /// needs this yet; kept for the next plan that must distinguish "new
    /// tier" ids from "legacy Pro" ids (e.g. a grandfathering plan).
    public static let readerAndVoice: [String] = [
        readerMonthly, readerAnnual, voiceMonthly, voiceAnnual,
    ]
}
```

- [ ] **Step 2: Point `EntitlementLevel.initialize` at the shared list**

In `EntitlementLevel.swift`, replace:

```swift
    public static func initialize(productId: String)->EntitlementLevel {
        switch productId {
        case _ where ["org.fidexa.rishi.pro.monthly","org.fidexa.rishi.pro.annual"].contains(productId):
                .init(state: .subscribed)
            
        default :
                .init(state: .unsubscribed)
            
        }
    }
```

with:

```swift
    public static func initialize(productId: String)->EntitlementLevel {
        switch productId {
        case _ where RishiProductID.all.contains(productId):
                .init(state: .subscribed)
            
        default :
                .init(state: .unsubscribed)
            
        }
    }
```

`EntitlementLevel` stays a coarse binary flag (`.subscribed`/`.unsubscribed`) — it does **not** gain Reader-vs-Voice tier awareness here. Distinguishing tiers for allowance/UI purposes is the entitlement-snapshot-client plan's job, reading the Worker's authoritative `EntitlementSnapshot`; this plan only needs "is this product one of ours."

- [ ] **Step 3: Point `Store.fetchProductIDs()` at the shared list**

In `Store.swift`, replace:

```swift
func fetchProductIDs()->[ProductID]{
    return ["org.fidexa.rishi.pro.monthly","org.fidexa.rishi.pro.annual"]
}
```

with:

```swift
func fetchProductIDs()->[ProductID]{
    return RishiProductID.all
}
```

- [ ] **Step 4: Verify**

```bash
swift build --package-path apps/apple/Packages/RishiBilling
```

Expected: builds clean (`EntitlementLevel.swift` and `Store.swift` are `@available(iOS 18.4, *)`; building for the host macOS toolchain still type-checks these against the package's declared `.iOS(.v18)` platform via cross-compilation checks — if `swift build` complains about platform availability rather than a real type error, fall back to `xcrun --sdk iphonesimulator swiftc -typecheck` on the two changed files instead).

- [ ] **Step 5: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/Models/RishiProductID.swift \
  Packages/RishiBilling/Sources/RishiBilling/Models/EntitlementLevel.swift \
  Packages/RishiBilling/Sources/RishiBilling/StoreKit/Store.swift
git commit -m "feat(billing): add Reader/Voice product ID constants alongside legacy Pro"
```

---

### Task 2: Add the four products to both `.storekit` configs

**Files:**
- Modify: `apps/apple/rishi/Rishi Reader.storekit` (schema v5 — matches its existing `billingPlans`/`introductoryOffers`/`winbackOffers` shape)
- Modify: `Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit` (schema v4 — matches its existing singular `introductoryOffer` shape)

Neither product exists in App Store Connect yet — that is an explicitly out-of-scope follow-up (see "Exports for downstream plans"). Local `.storekit` configuration files run fully offline in Simulator/SKTestSession with no ASC linkage required, so placeholder `internalID` strings (matching the test file's existing `RISHI_PRO_MONTHLY_INTERNAL`-style placeholders) are correct here, not a shortcut.

- [ ] **Step 1: `Rishi Reader.storekit` — append a new subscription group**

In `apps/apple/rishi/Rishi Reader.storekit`, the `subscriptionGroups` array currently has one element (`"Rishi Pro"`, id `"22149819"`). Add a second element to that array (do not modify the existing "Rishi Pro" group at all):

```json
    {
      "id" : "rishi-reader-voice-group",
      "localizations" : [
        {
          "description" : "Rishi Reader and Rishi Voice subscriptions",
          "displayName" : "Rishi Reader & Voice",
          "locale" : "en_US"
        }
      ],
      "name" : "Rishi Reader & Voice",
      "subscriptions" : [
        {
          "adHocOffers" : [

          ],
          "billingPlans" : [
            {
              "billingPlanType" : "BILLED_UPFRONT",
              "commitmentDisplayPrice" : "14.99",
              "displayPrice" : "14.99",
              "internalID" : "RISHI_VOICE_MONTHLY_INTERNAL_BILLED_UPFRONT",
              "isEnabled" : true
            }
          ],
          "codeOffers" : [

          ],
          "displayPrice" : "14.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "RISHI_VOICE_MONTHLY_INTERNAL",
          "introductoryOffers" : [

          ],
          "localizations" : [
            {
              "description" : "12h AI narration, 180 min Voice Chat monthly.",
              "displayName" : "Rishi Voice Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.voice.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Rishi Voice Monthly",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        },
        {
          "adHocOffers" : [

          ],
          "billingPlans" : [
            {
              "billingPlanType" : "BILLED_UPFRONT",
              "commitmentDisplayPrice" : "143.99",
              "displayPrice" : "143.99",
              "internalID" : "RISHI_VOICE_ANNUAL_INTERNAL_BILLED_UPFRONT",
              "isEnabled" : true
            }
          ],
          "codeOffers" : [

          ],
          "displayPrice" : "143.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "RISHI_VOICE_ANNUAL_INTERNAL",
          "introductoryOffers" : [

          ],
          "localizations" : [
            {
              "description" : "12h AI narration, 180 min Voice Chat. Billed yearly.",
              "displayName" : "Rishi Voice Annual",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.voice.annual",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Rishi Voice Annual",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        },
        {
          "adHocOffers" : [

          ],
          "billingPlans" : [
            {
              "billingPlanType" : "BILLED_UPFRONT",
              "commitmentDisplayPrice" : "7.99",
              "displayPrice" : "7.99",
              "internalID" : "RISHI_READER_MONTHLY_INTERNAL_BILLED_UPFRONT",
              "isEnabled" : true
            }
          ],
          "codeOffers" : [

          ],
          "displayPrice" : "7.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "RISHI_READER_MONTHLY_INTERNAL",
          "introductoryOffers" : [

          ],
          "localizations" : [
            {
              "description" : "6h AI narration, 90 min Voice Chat monthly.",
              "displayName" : "Rishi Reader Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.reader.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Rishi Reader Monthly",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        },
        {
          "adHocOffers" : [

          ],
          "billingPlans" : [
            {
              "billingPlanType" : "BILLED_UPFRONT",
              "commitmentDisplayPrice" : "76.99",
              "displayPrice" : "76.99",
              "internalID" : "RISHI_READER_ANNUAL_INTERNAL_BILLED_UPFRONT",
              "isEnabled" : true
            }
          ],
          "codeOffers" : [

          ],
          "displayPrice" : "76.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "RISHI_READER_ANNUAL_INTERNAL",
          "introductoryOffers" : [

          ],
          "localizations" : [
            {
              "description" : "6h AI narration, 90 min Voice Chat. Billed yearly.",
              "displayName" : "Rishi Reader Annual",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.reader.annual",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Rishi Reader Annual",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        }
      ]
    }
```

Remember the trailing comma after the existing "Rishi Pro" group's closing `}` before this new object, and keep this new group as the last element before the `subscriptionGroups` array's closing `]`.

- [ ] **Step 2: `Rishi.storekit` (test fixture) — append the matching v4-schema group**

Add a second element to that file's `subscriptionGroups` array (after the existing `"rishi-pro-group"` element):

```json
    {
      "id" : "rishi-reader-voice-group",
      "localizations" : [
        { "description" : "Rishi Reader and Rishi Voice subscriptions", "displayName" : "Rishi Reader & Voice", "locale" : "en_US" }
      ],
      "name" : "Rishi Reader & Voice",
      "subscriptions" : [
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "14.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "RISHI_VOICE_MONTHLY_INTERNAL",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "12h AI narration, 180 min Voice Chat monthly.",
              "displayName" : "Rishi Voice Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.voice.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Rishi Voice Monthly",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription"
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "143.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "RISHI_VOICE_ANNUAL_INTERNAL",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "12h AI narration, 180 min Voice Chat. Billed yearly.",
              "displayName" : "Rishi Voice Annual",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.voice.annual",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Rishi Voice Annual",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription"
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "7.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "RISHI_READER_MONTHLY_INTERNAL",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "6h AI narration, 90 min Voice Chat monthly.",
              "displayName" : "Rishi Reader Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.reader.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Rishi Reader Monthly",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription"
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "76.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "RISHI_READER_ANNUAL_INTERNAL",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "6h AI narration, 90 min Voice Chat. Billed yearly.",
              "displayName" : "Rishi Reader Annual",
              "locale" : "en_US"
            }
          ],
          "productID" : "org.fidexa.rishi.reader.annual",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Rishi Reader Annual",
          "subscriptionGroupID" : "rishi-reader-voice-group",
          "type" : "RecurringSubscription"
        }
      ]
    }
```

- [ ] **Step 3: Verify both files are valid JSON**

```bash
python3 -c "import json; json.load(open('apps/apple/rishi/Rishi Reader.storekit'))" && echo OK
python3 -c "import json; json.load(open('apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit'))" && echo OK
```

Expected: `OK` printed twice. (StoreKit config files are plain JSON — Xcode's SKTestSession loader will fail silently on malformed JSON, so this parse check is the fast local gate before ever opening Xcode.)

- [ ] **Step 4: Commit**

```bash
cd apps/apple && git add "rishi/Rishi Reader.storekit" \
  "Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit"
git commit -m "feat(billing): add Reader/Voice StoreKit products to local test configs"
```

---

### Task 3: `AppAccountToken` — UUID v5 derivation matching the Worker byte-for-byte

**Files:**
- Create: `Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppAccountToken.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import CryptoKit
import StoreKit
import RishiCore

/// Derives and supplies the `appAccountToken` StoreKit purchase option that
/// links an Apple transaction to the authenticated Rishi user, per the
/// 2026-07-17 pricing/trial-launch design doc's "Authoritative entitlement
/// model": *"When an authenticated user initiates an Apple purchase, Rishi
/// passes that user's stable `appAccountToken` UUID in StoreKit's purchase
/// options... The Worker accepts an entitlement sync only when... the
/// transaction's `appAccountToken` matches the authenticated Rishi user."*
public enum AppAccountToken {

    /// Fixed RFC 4122 v5 namespace. MUST byte-for-byte match the Worker's
    /// `APP_ACCOUNT_TOKEN_NAMESPACE` constant in
    /// `workers/worker/src/billing/entitlement-sync.ts` — changing this
    /// silently breaks every previously derived token's match against the
    /// Worker. Generated once (2026-07-17); never regenerate.
    private static let namespace = "fbf6524d-646b-4317-b479-476821e250f6"

    /// Deterministic UUID v5 = SHA-1(namespaceBytes ++ utf8Bytes(userId)),
    /// with the version nibble (byte 6) and RFC 4122 variant bits (byte 8)
    /// patched exactly as the Worker's `deriveAppAccountToken` does. Same
    /// `userId` always yields the same `UUID`; the Worker computes the
    /// identical value independently, so no round trip or new storage is
    /// needed to keep the two in sync.
    ///
    /// `userId` MUST be the Worker's Rishi `user.id` string — Better Auth's
    /// 32-character alphanumeric `generateId()` output, exposed to this app
    /// as ``Session/userId`` (persisted by ``KeychainSessionStore``). Do
    /// NOT pass `RishiCore`'s local `UserID`/`DerivedUserID` — those are
    /// unrelated, purely-local UUID-shaped storage keys.
    public static func derive(userId: String) -> UUID {
        let namespaceBytes = uuidStringToBytes(namespace)
        let nameBytes = Array(userId.utf8)
        let digest = Insecure.SHA1.hash(data: Data(namespaceBytes + nameBytes))
        var hash = Array(digest.prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50 // version 5
        hash[8] = (hash[8] & 0x3f) | 0x80 // RFC 4122 variant
        return uuid(fromBytes: hash)
    }

    /// StoreKit purchase options for the currently signed-in user, ready to
    /// pass to `product.purchase(options:)`, the `\.purchase` `PurchaseAction`,
    /// or `SubscriptionStoreView`'s `.inAppPurchaseOptions(_:)`. Returns an
    /// empty set (StoreKit's own default — no `appAccountToken` attached)
    /// if no session is currently persisted. The paywall is only reachable
    /// while signed in, so this is a defensive fallback, not an expected
    /// path; a purchase without a token simply cannot be matched to a Rishi
    /// account server-side, which the Worker's entitlement-sync guard
    /// already rejects safely (`app_account_token_mismatch`).
    public static func currentPurchaseOptions(
        sessionStore: KeychainSessionStore = KeychainSessionStore()
    ) async -> Set<Product.PurchaseOption> {
        guard let session = try? await sessionStore.load() else { return [] }
        return [.appAccountToken(derive(userId: session.userId))]
    }

    // MARK: - Byte plumbing (mirrors the Worker's uuidStringToBytes 1:1)

    private static func uuidStringToBytes(_ uuidString: String) -> [UInt8] {
        let hex = uuidString.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// Swift's native tuple-based `UUID(uuid:)` initializer replaces the
    /// Worker's separate `bytesToUuidString` string-formatting step — same
    /// 16 bytes in, same canonical UUID out, no string-formatting bugs
    /// possible on this side.
    private static func uuid(fromBytes bytes: [UInt8]) -> UUID {
        precondition(bytes.count == 16)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
```

- [ ] **Step 2: Verify**

```bash
swift build --package-path apps/apple/Packages/RishiBilling
```

- [ ] **Step 3: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppAccountToken.swift
git commit -m "feat(billing): add AppAccountToken UUID v5 derivation matching the Worker"
```

---

### Task 4: Entitlement-sync endpoint + DI-friendly client

**Files:**
- Create: `Packages/RishiCore/Sources/RishiCore/Endpoints/EntitlementSyncEndpoint.swift`
- Create: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncClient.swift`

- [ ] **Step 1: The typed Worker endpoint (`RishiCore`)**

```swift
import Foundation

/// `POST /api/billing/entitlement-sync` — submits a StoreKit transaction's
/// signed JWS so the Worker can verify it locally, cross-check the derived
/// `appAccountToken`, persist the entitlement, and start the user's
/// allowance period if needed. See
/// `workers/worker/src/billing/entitlement-sync.ts` and
/// `docs/superpowers/plans/2026-07-17-storekit-entitlement-sync.md`'s
/// "Exports for downstream plans" for the full server-side contract this
/// mirrors.
///
/// `ResponseBody` intentionally does NOT decode the response's `snapshot`
/// field into a typed `EntitlementSnapshot`. That union type, and
/// consuming/caching it, belongs to the separate "entitlement-snapshot-client"
/// plan (which already owns `/api/billing/me`'s response for the same
/// reason). This endpoint only needs to know whether the Worker accepted
/// the transaction; `Decodable`'s default behavior ignores the unknown
/// `snapshot` key, so this stays forward-compatible with no change needed
/// once that other plan lands.
public struct EntitlementSyncEndpoint: WorkerEndpointWithBody {
    public typealias Response = ResponseBody

    public let method: HTTPMethod = .POST
    public let path: String = "/api/billing/entitlement-sync"
    public let body: Request

    public init(body: Request) {
        self.body = body
    }

    public struct Request: Codable, Sendable, Equatable {
        public let transactionJWS: String

        public init(transactionJWS: String) {
            self.transactionJWS = transactionJWS
        }
    }

    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let verified: Bool
        public let reason: String?

        public init(verified: Bool, reason: String?) {
            self.verified = verified
            self.reason = reason
        }
    }
}
```

- [ ] **Step 2: The protocol seam + production client (`RishiBilling`)**

```swift
import Foundation
import RishiCore
import RishiLogging

/// Protocol seam so ``PurchaseService`` (and any future paywall code) can
/// be tested with a stub instead of a real ``WorkerClient``. Mirrors
/// ``ReceiptVerifier``'s existing seam shape.
public protocol EntitlementSyncing: Sendable {
    /// Fire-and-log entitlement sync: POST the transaction's JWS to
    /// `/api/billing/entitlement-sync`. Errors are logged, never thrown —
    /// every call site already finished the StoreKit transaction by the
    /// time this runs, so a transport failure here must not unwind or
    /// retry the purchase/restore flow itself. The next sync opportunity
    /// (another purchase, restore, or `Transaction.updates` event) will
    /// naturally retry, because StoreKit replays the same signed JWS for
    /// as long as the transaction remains in the user's entitlement set.
    func sync(transactionJWS: String) async
}

/// Production ``EntitlementSyncing`` wrapping ``WorkerClient``. Follows
/// ``WorkerReceiptVerifier``'s DI shape (actor + injected `WorkerClient`).
public actor EntitlementSyncClient: EntitlementSyncing {
    private let client: WorkerClient

    public init(client: WorkerClient) {
        self.client = client
    }

    public func sync(transactionJWS: String) async {
        do {
            let response = try await client.send(
                EntitlementSyncEndpoint(body: .init(transactionJWS: transactionJWS))
            )
            Log.event("iap.entitlement_sync.done", level: .info,
                      data: ["verified": "\(response.verified)"])
        } catch {
            Log.event("iap.entitlement_sync.failed", level: .warning,
                      data: ["error": String(describing: error)])
        }
    }
}
```

- [ ] **Step 3: Verify**

```bash
swift build --package-path apps/apple/Packages/RishiCore
swift build --package-path apps/apple/Packages/RishiBilling
```

- [ ] **Step 4: Commit**

```bash
cd apps/apple && git add Packages/RishiCore/Sources/RishiCore/Endpoints/EntitlementSyncEndpoint.swift \
  Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncClient.swift
git commit -m "feat(billing): add EntitlementSyncEndpoint and EntitlementSyncClient"
```

---

### Task 5: Wire `PurchaseService` — `appAccountToken` on purchase, sync after every StoreKit-verified transaction

**Files:**
- Modify: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/PurchaseService.swift`

**Signature-compatibility constraint:** `PurchaseServiceTests.swift` and `TransactionListenerTests.swift` construct `PurchaseService` with `productFetcher:verifier:reconciler:` (and sometimes a trailing `purchaseClosure:`) and never pass a fifth parameter. The new `entitlementSyncClient` parameter below is added with a default value so none of those call sites need to change, and the existing `purchaseClosure` parameter's **type is left untouched** — tests that inject a closure returning `.userCancelled`/`.pending` (which `SKTestSession` cannot reliably synthesize) keep working exactly as today. Only the *default* closure (used when `purchaseClosure` is `nil`, i.e. real production purchases) changes to pass purchase options.

- [ ] **Step 1: Add the `RishiCore` import and the `entitlementSyncClient` dependency**

At the top of the file:

```swift
import Foundation
import StoreKit
import RishiLogging
import RishiCore
```

- [ ] **Step 2: Add the stored property and update `init`**

Replace:

```swift
    private let productFetcher: any ProductFetching
    private let verifier: any ReceiptVerifier
    private let reconciler: EntitlementReconciler
    private let purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)
```

with:

```swift
    private let productFetcher: any ProductFetching
    private let verifier: any ReceiptVerifier
    private let reconciler: EntitlementReconciler
    private let entitlementSyncClient: any EntitlementSyncing
    private let purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)
```

Replace the `init`:

```swift
    @available(iOS 18.4, *)
    public init(
        productFetcher: any ProductFetching,
        verifier: any ReceiptVerifier,
        reconciler: EntitlementReconciler,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil
    ) {
        self.productFetcher = productFetcher
        self.verifier = verifier
        self.reconciler = reconciler
        self.purchaseClosure = purchaseClosure ?? { product in try await product.purchase() }
    }
```

with:

```swift
    @available(iOS 18.4, *)
    public init(
        productFetcher: any ProductFetching,
        verifier: any ReceiptVerifier,
        reconciler: EntitlementReconciler,
        entitlementSyncClient: (any EntitlementSyncing)? = nil,
        purchaseClosure: (@Sendable (Product) async throws -> Product.PurchaseResult)? = nil
    ) {
        self.productFetcher = productFetcher
        self.verifier = verifier
        self.reconciler = reconciler
        self.entitlementSyncClient = entitlementSyncClient ?? Self.defaultEntitlementSyncClient()
        self.purchaseClosure = purchaseClosure ?? { product in
            let options = await AppAccountToken.currentPurchaseOptions()
            return try await product.purchase(options: options)
        }
    }

    /// Built the same way `WorkerEndpoint.send()` builds its own client:
    /// `RISHI_API_URL` env var (falling back to the production API host) +
    /// `KeychainSessionStore`-backed `RishiAuthTokenProvider`. Only used
    /// when the caller does not inject a stub (tests always inject one via
    /// `entitlementSyncClient:`).
    private static func defaultEntitlementSyncClient() -> any EntitlementSyncing {
        let baseURLString = ProcessInfo.processInfo.environment["RISHI_API_URL"]
            ?? "https://api.fidexa.org"
        let baseURL = URL(string: baseURLString) ?? URL(string: "https://api.fidexa.org")!
        let tokenProvider = RishiAuthTokenProvider(keychain: KeychainSessionStore())
        return EntitlementSyncClient(client: WorkerClient(baseURL: baseURL, tokenProvider: tokenProvider))
    }
```

- [ ] **Step 3: Sync after every StoreKit-verified purchase in `handleVerified`**

In `handleVerified`, after each `await tx.finish()`, add the sync call. The method becomes:

```swift
    private func handleVerified(
        _ result: VerificationResult<Transaction>,
        productId: String
    ) async throws -> PurchaseOutcome {
        let tx: Transaction
        do {
            tx = try result.payloadValue
        } catch {
            Log.event("iap.purchase.unverified", level: .error,
                      data: ["error": String(describing: error)])
            // Do NOT finish. Apple replays via Transaction.updates.
            throw PurchaseError.unverifiedReceipt
        }

        inFlightTransactionIds.insert(tx.id)
        defer { inFlightTransactionIds.remove(tx.id) }

        let resp: VerifyReceiptResponse
        do {
            resp = try await verifier.verify(
                jws: result.jwsRepresentation,
                productId: tx.productID,
                transactionId: tx.id
            )
        } catch {
            // Transport failure — leave UNFINISHED so Transaction.unfinished
            // replays on next launch (RESEARCH §3.3).
            Log.event("iap.purchase.worker_unreachable", level: .warning,
                      data: ["tx": "\(tx.id)", "error": String(describing: error)])
            throw PurchaseError.workerUnreachable(String(describing: error))
        }

        if resp.verified {
            await tx.finish()
            await MainActor.run { self.reconciler.setOnDevice(.subscribed) }
            await entitlementSyncClient.sync(transactionJWS: result.jwsRepresentation)
            Log.event("iap.purchase.granted", level: .info,
                      data: ["tx": "\(tx.id)", "productId": productId])
            return .granted(premiumUntil: resp.premiumUntil)
        } else {
            // Worker rejected — finish to break the loop; reconciler stays free.
            await tx.finish()
            await entitlementSyncClient.sync(transactionJWS: result.jwsRepresentation)
            Log.event("iap.purchase.worker_rejected", level: .warning,
                      data: ["tx": "\(tx.id)", "reason": resp.reason ?? "unknown"])
            return .rejected(reason: resp.reason ?? "unknown")
        }
    }
```

Sync fires in **both** branches: `/api/billing/entitlement-sync` is an independent, authoritative check on the Worker side — it does not defer to the older `/api/billing/verify-receipt` route's opinion (`resp.verified`), so both StoreKit-verified outcomes are reported to it.

- [ ] **Step 4: Same for `processUpdate`'s granted/rejected branches**

```swift
    public func processUpdate(_ result: VerificationResult<Transaction>, source: String) async {
        guard case .verified(let tx) = result else {
            Log.event("iap.update.unverified", level: .warning, data: ["source": source])
            return
        }
        // Skip if the same-session purchase path is already verifying this id.
        if inFlightTransactionIds.contains(tx.id) {
            Log.event("iap.update.skip_in_flight", level: .info,
                      data: ["tx": "\(tx.id)", "source": source])
            return
        }
        do {
            let resp = try await verifier.verify(
                jws: result.jwsRepresentation,
                productId: tx.productID,
                transactionId: tx.id
            )
            if resp.verified {
                await tx.finish()
                await MainActor.run { self.reconciler.setOnDevice(.subscribed) }
                await entitlementSyncClient.sync(transactionJWS: result.jwsRepresentation)
                Log.event("iap.update.granted_and_finished", level: .info,
                          data: ["tx": "\(tx.id)", "source": source])
            } else {
                // Worker rejected — finish to break the loop.
                await tx.finish()
                await entitlementSyncClient.sync(transactionJWS: result.jwsRepresentation)
                Log.event("iap.update.rejected_and_finished", level: .warning,
                          data: [
                              "tx": "\(tx.id)",
                              "reason": resp.reason ?? "unknown",
                              "source": source,
                          ])
            }
        } catch {
            // Transport failure — leave UNFINISHED for the next-launch replay.
            Log.event("iap.update.verify_threw_left_unfinished", level: .warning,
                      data: [
                          "tx": "\(tx.id)",
                          "error": String(describing: error),
                          "source": source,
                      ])
        }
    }
```

- [ ] **Step 5: Verify**

```bash
swift test --package-path apps/apple/Packages/RishiBilling
```

Expected: all existing `PurchaseServiceTests`, `TransactionListenerTests`, `PaywallOnSubscribeWiringTests` pass unchanged (no test file is modified by this plan).

- [ ] **Step 6: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/StoreKit/PurchaseService.swift
git commit -m "feat(billing): wire appAccountToken and entitlement-sync into PurchaseService"
```

---

### Task 6: Wire `appAccountToken` into the live `SubscriptionStoreView` paywall

**Files:**
- Modify: `apps/apple/rishi/rishi/Billing/SubscriptionsView.swift`

- [ ] **Step 1: Add `.inAppPurchaseOptions(_:)`**

Add this modifier to the `SubscriptionStoreView` (placement among the other modifiers doesn't matter functionally — grouped here next to the other StoreKit-view modifiers for readability):

```swift
                SubscriptionStoreView(groupID: groupId.value) {
                    
                    VStack {
                        
                        Image("rishi")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .clipShape(.rect(cornerRadius: 20))
                        Text("Rishi Reader")
                            .fontWeight(.semibold)
                            .font(.largeTitle)
                        VStack(spacing: 10) {
                            Text("Bring every book to life")
                                .font(.headline)
                                .foregroundStyle(.blue)
                            Text(
                                "Listen to books with natural voices, ask questions as you read, and pick up where you left off on any device"
                            )
                        }.padding(10)
                            .multilineTextAlignment(.center)
                        
                    }
                    
                }
                .inAppPurchaseOptions { _ in
                    await AppAccountToken.currentPurchaseOptions()
                }
                .subscriptionStoreButtonLabel(.multiline)
```

(i.e. insert `.inAppPurchaseOptions { _ in await AppAccountToken.currentPurchaseOptions() }` directly after the `SubscriptionStoreView { ... }` closure and before the existing `.subscriptionStoreButtonLabel(.multiline)` — every other modifier in the file is unchanged.)

No new import is needed — `RishiBilling` is already imported by this file, and `AppAccountToken` is one of its public types (Task 3).

**Why no change to `.checkCustomerEntitlements()` or the app-wide `.onInAppPurchaseCompletion`:** `RootView.swift`'s `.onInAppPurchaseCompletion { product, result in ... Store.shared.process(purchaseResult:) ... }` is attached near the root of the view hierarchy and, per StoreKit's documented behavior, observes completions from **every** descendant `SubscriptionStoreView`/`ProductView`/`StoreView` in the tree — including this one. `SubscriptionsView` does not need its own separate completion handler; Task 7/8 below update what that existing handler calls into (`Store.process` → `CustomerEntitlements.process`) to carry the JWS through.

- [ ] **Step 2: Verify**

```bash
xcrun --sdk iphonesimulator swiftc -typecheck "apps/apple/rishi/rishi/Billing/SubscriptionsView.swift"
```

(This single-file typecheck will report unrelated missing-module errors since it can't see the rest of the app target's imports resolved standalone — confirm no *new* diagnostic mentions `inAppPurchaseOptions` or `AppAccountToken` specifically; a full clean build check happens at Task 11.)

- [ ] **Step 3: Commit**

```bash
cd apps/apple && git add rishi/rishi/Billing/SubscriptionsView.swift
git commit -m "feat(billing): pass appAccountToken through SubscriptionStoreView purchases"
```

---

### Task 7: Fire-and-forget sync helper + wire it into `CustomerEntitlements`

**Files:**
- Create: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncFireAndForget.swift`
- Modify: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/CustomerEntitlements.swift`

- [ ] **Step 1: The shared internal helper**

```swift
import Foundation
import RishiCore
import RishiLogging

/// Fire-and-forget entitlement sync for call sites that are bare
/// singletons with no dependency-injection surface today (``Store``,
/// ``CustomerEntitlements``, ``RestoreService``). Builds its own throwaway
/// `WorkerClient` per call via `EntitlementSyncEndpoint(...).send()` — the
/// exact same pattern the existing `VerifyEndPont(...).send()` call in
/// `CustomerEntitlements.observeTransactionUpdates()` already uses, rather
/// than retrofitting constructor injection onto three singletons that have
/// none today.
///
/// Errors are logged only, never thrown — see
/// ``EntitlementSyncing/sync(transactionJWS:)``'s doc for why a transport
/// failure here must not unwind the caller. Runs detached at `.background`
/// priority so it never delays finishing a transaction or returning a
/// restore/purchase outcome to the UI.
///
/// ``PurchaseService`` does NOT use this helper — it already has a real DI
/// graph (``EntitlementSyncClient``, see Task 4) and keeps using that for
/// testability.
func syncEntitlementFireAndForget(jws: String) {
    Task.detached(priority: .background) {
        do {
            let response = try await EntitlementSyncEndpoint(
                body: .init(transactionJWS: jws)
            ).send()
            Log.event("iap.entitlement_sync.done", level: .info,
                      data: ["verified": "\(response.verified)"])
        } catch {
            Log.event("iap.entitlement_sync.failed", level: .warning,
                      data: ["error": String(describing: error)])
        }
    }
}
```

- [ ] **Step 2: `CustomerEntitlements.process(transaction:)` → `process(transaction:jws:)`**

Replace:

```swift
    public func process(transaction: Transaction) async {
            await transaction.finish()
    }
```

with:

```swift
    public func process(transaction: Transaction, jws: String) async {
            await transaction.finish()
            syncEntitlementFireAndForget(jws: jws)
    }
```

- [ ] **Step 3: Update `observeTransactionUpdates()`** — loop variable `update` is untouched, just pass its `jwsRepresentation` through:

```swift
    public func observeTransactionUpdates() {
        transactionUpdatesTask = Task { [weak self] in
            logger.debug("Observing transaction updates")
            for await update in Transaction.updates {
                guard let self else { return }
                guard let transaction = await unwrapVerificationResult(update) else { continue }
             
               
            
                await self.process(transaction: transaction, jws: update.jwsRepresentation)
                
                do {
                    try await VerifyEndPont(body: .init(transactionId: transaction.id)).send()
                }catch {
                    print(error)
                }
             
            }
        }
    }
```

(The pre-existing `VerifyEndPont` call to the older `/auth/verify-transaction` route is left untouched — it is a separate legacy path noted in the task brief, not owned by this plan; removing it is a follow-up once the new entitlement-sync path is confirmed working in production, not something to drive-by-delete here.)

- [ ] **Step 4: Update `checkForCurrentEntitlements()`** — rename the loop variable so the original `VerificationResult` (needed for `.jwsRepresentation`) is not shadowed by the unwrapped `Transaction`:

```swift
    public func checkForCurrentEntitlements() async {
        logger.debug("Checking for current entitlements")
        for await result in Transaction.currentEntitlements {
            guard let transaction = await unwrapVerificationResult(result) else {
                logger.error("Encountered error while checking for current entitlements")
                return
            }
            logger.log("""
            Processing current entitlement \(transaction.id) for \
            \(transaction.productID)
            """)
//            SubscriptionService.shared.saveSubscription(subscription: .subscribed)
            let jws = result.jwsRepresentation
            Task.detached(priority: .background) {
                await self.process(transaction: transaction, jws: jws)
                
            }
        }
        logger.debug("Finished checking for current entitlements")
    }
```

- [ ] **Step 5: Update `checkForUnfinishedTransactions()`** — same rename:

```swift
    public func checkForUnfinishedTransactions() async {
        logger.debug("Checking for unfinished transactions")
        for await result in Transaction.unfinished {
            guard let transaction = await unwrapVerificationResult(result) else {
                logger.error("Encountered error while checking for unfinished transactions")
                return
            }
            logger.log("""
            Processing unfinished transaction ID \(transaction.id) for \
            \(transaction.productID)
            """)
            let jws = result.jwsRepresentation
            Task.detached(priority: .background) {
                await self.process(transaction: transaction, jws: jws)
            }
        }
        logger.debug("Finished checking for unfinished transactions")
    }
```

- [ ] **Step 6: Verify**

```bash
swift build --package-path apps/apple/Packages/RishiBilling
```

- [ ] **Step 7: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncFireAndForget.swift \
  Packages/RishiBilling/Sources/RishiBilling/StoreKit/CustomerEntitlements.swift
git commit -m "feat(billing): sync entitlement after every transaction CustomerEntitlements observes"
```

---

### Task 8: Update `Store.process(purchaseResult:)` — the one external caller of `CustomerEntitlements.process`

**Files:**
- Modify: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/Store.swift`

- [ ] **Step 1: Forward the JWS**

Replace:

```swift
            await CustomerEntitlements.shared.process(transaction: transaction)
```

with:

```swift
            await CustomerEntitlements.shared.process(
                transaction: transaction,
                jws: verificationResult.jwsRepresentation
            )
```

`verificationResult` is already in scope (the `case .success(let verificationResult):` binding a few lines above) — no other change to this method.

- [ ] **Step 2: Verify**

```bash
swift build --package-path apps/apple/Packages/RishiBilling
```

- [ ] **Step 3: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/StoreKit/Store.swift
git commit -m "feat(billing): forward JWS through Store.process to CustomerEntitlements"
```

---

### Task 9: `RestoreService` — fix the product filter and sync every restored transaction

**Files:**
- Modify: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/RestoreService.swift`

- [ ] **Step 1: Fix `readActiveProductIds()`'s filter and add the sync call**

Replace:

```swift
    private func readActiveProductIds() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            guard tx.productID.hasPrefix(Self.productIdPrefix) else { continue }
            guard tx.revocationDate == nil else { continue }
            ids.append(tx.productID)
        }
        return ids
    }
```

with:

```swift
    private func readActiveProductIds() async -> [String] {
        var ids: [String] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result else { continue }
            // `EntitlementLevel.initialize` (RishiProductID.all) recognizes
            // both the legacy Pro ids and the four new Reader/Voice ids —
            // the old `productIdPrefix`-only check below would have
            // silently excluded every Reader/Voice restore.
            guard EntitlementLevel.initialize(productId: tx.productID) == .subscribed else { continue }
            guard tx.revocationDate == nil else { continue }
            ids.append(tx.productID)
            syncEntitlementFireAndForget(jws: result.jwsRepresentation)
        }
        return ids
    }
```

This single change covers both `restore()` (user-initiated) and `refreshOnDeviceEntitlementAtLaunch()` (currently unwired dead code — see Context item 8) the moment either one runs, with no further change needed to either caller.

- [ ] **Step 2: Update `productIdPrefix`'s doc comment** to avoid implying it is still the sole filter:

Replace:

```swift
    /// Product ID prefix for the Rishi Pro tier — matches both
    /// `org.fidexa.rishi.pro.monthly` and `org.fidexa.rishi.pro.annual`.
    /// Centralized constant so future tiers cannot accidentally be missed
    /// by an out-of-band productID filter elsewhere.
    public static let productIdPrefix = "org.fidexa.rishi.pro."
```

with:

```swift
    /// Product ID prefix for the legacy Rishi Pro tier — matches both
    /// `org.fidexa.rishi.pro.monthly` and `org.fidexa.rishi.pro.annual`.
    /// Kept as public API for source compatibility; `readActiveProductIds()`
    /// below no longer uses this alone for filtering — it checks
    /// `EntitlementLevel.initialize(productId:) == .subscribed`
    /// (`RishiProductID.all`), which covers this prefix's two ids plus the
    /// four Reader/Voice ids, so a future new tier only needs to be added
    /// to `RishiProductID.all` once, not duplicated here too.
    public static let productIdPrefix = "org.fidexa.rishi.pro."
```

- [ ] **Step 3: Verify**

```bash
swift test --package-path apps/apple/Packages/RishiBilling
```

Expected: `RestoreServiceTests` pass unchanged — the public `RestoreOutcome`/`restore()` shape is untouched; only the private filter and a fire-and-forget side effect changed.

- [ ] **Step 4: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/StoreKit/RestoreService.swift
git commit -m "fix(billing): recognize Reader/Voice products in restore, sync each restored transaction"
```

---

### Task 10: Update the public API index

**Files:**
- Modify: `Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`

- [ ] **Step 1: Add entries for the new public symbols**

Under `MARK: - Receipt verification`, add after the existing `ProductFetching` line:

```swift
// EntitlementSyncing            — `StoreKit/EntitlementSyncClient.swift`. Protocol seam.
// EntitlementSyncClient         — `StoreKit/EntitlementSyncClient.swift`. Actor. Production
//                                  sync client wrapping WorkerClient, POSTs to
//                                  /api/billing/entitlement-sync. Used by PurchaseService;
//                                  Store/CustomerEntitlements/RestoreService instead call
//                                  the internal syncEntitlementFireAndForget(jws:) helper.
```

Under `MARK: - Models / Types`, add:

```swift
// RishiProductID              — `Models/RishiProductID.swift`. The six Apple product ids
//                                (2 legacy Pro + 4 Reader/Voice) — single source of truth
//                                for Store.fetchProductIDs() and EntitlementLevel.initialize.
// AppAccountToken              — `Entitlements/AppAccountToken.swift`. UUID v5 derivation
//                                (byte-identical to the Worker's) + currentPurchaseOptions().
```

- [ ] **Step 2: Commit**

```bash
cd apps/apple && git add Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift
git commit -m "docs(billing): index new entitlement-sync and appAccountToken public symbols"
```

---

### Task 11: Final whole-package verification

**Files:** none (verification only)

- [ ] **Step 1: Build/test every touched package**

```bash
swift build --package-path apps/apple/Packages/RishiCore
swift test --package-path apps/apple/Packages/RishiCore
swift build --package-path apps/apple/Packages/RishiBilling
swift test --package-path apps/apple/Packages/RishiBilling
```

Expected: clean build, all pre-existing tests pass, no new failures. `RishiBillingTests` should show `PurchaseServiceTests`, `RestoreServiceTests`, `PaywallOnSubscribeWiringTests`, `TransactionListenerTests` all still green.

- [ ] **Step 2: Typecheck the one touched app-target file**

```bash
xcrun --sdk iphonesimulator swiftc -typecheck "apps/apple/rishi/rishi/Billing/SubscriptionsView.swift"
```

- [ ] **Step 3: Confirm both `.storekit` files are still valid JSON** (re-run Task 2 Step 3's check — cheap, catches any accidental edit drift before this plan's work is considered done)

```bash
python3 -c "import json; json.load(open('apps/apple/rishi/Rishi Reader.storekit'))" && echo OK
python3 -c "import json; json.load(open('apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Resources/Rishi.storekit'))" && echo OK
```

- [ ] **Step 4: Commit (only if Steps 1–3 required a fixup)**

If every prior task already committed cleanly, there is nothing new to commit here.

---

## Self-review notes

- **Spec coverage:** every numbered item in the task brief's "Your scope" has a corresponding task — (1) product ID constants (Task 1), (2) `.storekit` config additions (Task 2), (3) `deriveAppAccountToken` (Task 3), (4) purchase-options wiring for both `PurchaseService` and the live `SubscriptionStoreView` path (Tasks 5–6), (5) JWS extraction + new typed client (Task 4), (6) call sites at purchase completion / restore / transaction updates (Tasks 5, 7, 8, 9), plus the explicit app-lifecycle-hook decision (Context item 8, restated in "Exports" below).
- **No placeholders:** every function written above is complete, runnable Swift — the UUID v5 derivation is real byte manipulation (not a stub), the endpoint/client follow real existing patterns (`VerifyReceiptEndpoint`, `WorkerReceiptVerifier`) rather than inventing a new shape.
- **Signature-compatibility verified by reading the actual test files**, not assumed: `PurchaseServiceTests.swift`, `TransactionListenerTests.swift`, and `PaywallOnSubscribeWiringTests.swift` were read directly to confirm every existing `PurchaseService(...)` construction call keeps compiling after Task 5 (new parameter has a default; `purchaseClosure`'s type is unchanged).
- **Bug fixed in-scope, not drive-by:** `RestoreService`'s product-id-prefix filter (Task 9) would have silently broken restore for all four new products this plan adds — fixing it is required for this plan's own products to work, not an unrelated cleanup.
- **Bug left alone, correctly out of scope:** the test fixture's pre-existing `groupNumber` mismatch on the *existing* Pro group (Context item 3) is not touched — this plan's new group does not repeat that mistake, but "fixing" the old group is unrelated to adding new products.
- **Out of scope, correctly excluded:** App Store Connect product creation for the four new ids (no `setup_storekit_products.rb`-equivalent script run or written), subscriber grandfathering/migration off the legacy Pro tier, `EntitlementLevel` gaining Reader-vs-Voice tier awareness, consuming/caching the `EntitlementSnapshot` response body, and any new app-wide launch/foreground lifecycle hook (`scenePhase` observer) — each is called out explicitly above with the reasoning for leaving it to a named follow-up plan.

---

## Exports for downstream plans

### Product ID constants

`Packages/RishiBilling/Sources/RishiBilling/Models/RishiProductID.swift`:

```swift
public enum RishiProductID {
    public static let proMonthly = "org.fidexa.rishi.pro.monthly"       // legacy, kept
    public static let proAnnual = "org.fidexa.rishi.pro.annual"          // legacy, kept
    public static let readerMonthly = "org.fidexa.rishi.reader.monthly"  // new
    public static let readerAnnual = "org.fidexa.rishi.reader.annual"    // new
    public static let voiceMonthly = "org.fidexa.rishi.voice.monthly"    // new
    public static let voiceAnnual = "org.fidexa.rishi.voice.annual"      // new
    public static let all: [String]              // all six
    public static let readerAndVoice: [String]    // the four new ids only
}
```

Subscription group: one new StoreKit group (`"rishi-reader-voice-group"` in both local `.storekit` configs), `groupNumber: 1` for Voice (both durations), `groupNumber: 2` for Reader (both durations) — Voice ranked above Reader, matching the design doc. Not yet created in App Store Connect — a follow-up ops task (a sibling script to `apps/apple/scripts/setup_storekit_products.rb`) is required before these can be tested against the real App Store or TestFlight; local SKTestSession/Simulator testing works today with no ASC linkage.

### `appAccountToken` derivation

`Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppAccountToken.swift`:

```swift
public enum AppAccountToken {
    public static func derive(userId: String) -> UUID
    public static func currentPurchaseOptions(
        sessionStore: KeychainSessionStore = KeychainSessionStore()
    ) async -> Set<Product.PurchaseOption>
}
```

Byte-identical to the Worker's `deriveAppAccountToken` (`workers/worker/src/billing/entitlement-sync.ts`): RFC 4122 UUID v5, namespace `fbf6524d-646b-4317-b479-476821e250f6`, `SHA-1(namespaceBytes ++ utf8Bytes(userId))`, version nibble `0x50` on byte 6, variant bits `0x80` on byte 8. `userId` must be `Session.userId` (`KeychainSessionStore`), never `RishiCore`'s local `UserID`/`DerivedUserID`.

### Entitlement-sync client

`Packages/RishiCore/Sources/RishiCore/Endpoints/EntitlementSyncEndpoint.swift`:

```swift
public struct EntitlementSyncEndpoint: WorkerEndpointWithBody {
    public struct Request: Codable, Sendable, Equatable { public let transactionJWS: String }
    public struct ResponseBody: Decodable, Sendable, Equatable {
        public let verified: Bool
        public let reason: String?
        // `snapshot` is NOT decoded here — see "entitlement-snapshot-client" note below.
    }
}
```

`Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncClient.swift`:

```swift
public protocol EntitlementSyncing: Sendable {
    func sync(transactionJWS: String) async
}
public actor EntitlementSyncClient: EntitlementSyncing {
    public init(client: WorkerClient)
    public func sync(transactionJWS: String) async
}
```

Injected into `PurchaseService.init(..., entitlementSyncClient: (any EntitlementSyncing)? = nil, ...)`. For the bare singletons (`Store`, `CustomerEntitlements`, `RestoreService`), use the internal free function instead: `Packages/RishiBilling/Sources/RishiBilling/StoreKit/EntitlementSyncFireAndForget.swift`'s `func syncEntitlementFireAndForget(jws: String)` (module-internal, not `public` — call sites outside `RishiBilling` needing this behavior should go through `EntitlementSyncClient` directly, constructing their own `WorkerClient`).

### Call sites now firing entitlement sync (current state after this plan)

- **Purchase completion:** `Store.process(purchaseResult:)` → `CustomerEntitlements.process(transaction:jws:)` (app-wide, via `RootView.swift`'s `.onInAppPurchaseCompletion`, which also covers `SubscriptionsView`'s `SubscriptionStoreView` purchases) — fires once per successfully-verified StoreKit purchase.
- **Restore:** `RestoreService.restore()` (user-initiated "Restore Purchases") — fires once per currently-active, non-revoked, recognized-product transaction found.
- **StoreKit transaction updates:** `CustomerEntitlements.observeTransactionUpdates()` — fires for every `Transaction.updates` event, for as long as `CustomerEntitlements.shared.observeTransactionUpdates()` has been called (currently only from `SubscriptionsView`'s `.checkCustomerEntitlements()` appearance, per Context item 8).
- **Paywall-screen appearance (a "launch-ish" but not true app-launch signal):** `CustomerEntitlements.checkForCurrentEntitlements()` / `checkForUnfinishedTransactions()` — same trigger as above.
- **`PurchaseService`'s own path** (currently unwired into `ServiceGraphFactory` — see Context item 6): `handleVerified` and `processUpdate`, both branches.

### App-lifecycle hook decision: FLAGGED AS FOLLOW-UP, not built in this plan

No `scenePhase`/foreground observer exists anywhere in the app target today, and `RestoreService.refreshOnDeviceEntitlementAtLaunch()` — a method that already exists for exactly this purpose — is called from nowhere. This plan deliberately does not add a new app-wide launch/foreground hook (per the task brief's explicit instruction); it only wires the reusable sync call into paths that already run today.

**For the "entitlement-snapshot-client" plan (or whichever plan adds a `scenePhase` observer first):** when that hook is built, it should call, at both app launch and every foreground transition:
1. `RestoreService.refreshOnDeviceEntitlementAtLaunch()` — already implemented, already fires `syncEntitlementFireAndForget` per Task 9's change, just needs a real caller.
2. Whatever `/api/billing/me` (or its `EntitlementSnapshot`-typed successor) fetch that plan owns.

Wiring both from the same new hook (rather than two plans each adding a separate `scenePhase` observer) avoids duplicate lifecycle-observation code in the app target.

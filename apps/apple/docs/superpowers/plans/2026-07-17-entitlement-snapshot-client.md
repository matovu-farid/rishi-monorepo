# Entitlement snapshot client (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Testing override:** this plan contains **no test-writing steps**, by explicit user instruction. Every task verifies with `swift test --package-path apps/apple/Packages/<Package>` (package-level build/typecheck; existing suites still run, but no new tests are added) or, for app-target files, `xcrun --sdk iphonesimulator swiftc -typecheck <file>` per CLAUDE.md's `xcodebuild`-ban-for-subagents rule. Automated coverage for this client is a separate, later workstream (see both specs' "Deferred scope"/"Verification" sections) — do not add tests while executing this plan.
>
> **Build-clean precondition (CLAUDE.md):** before starting Task 1, confirm the two touched packages currently build: `swift test --package-path apps/apple/Packages/RishiCore` and `swift test --package-path apps/apple/Packages/RishiBilling`. If either is already broken, that is finding #1 — stop and surface it before writing new code.

**Goal:** Replace the iOS app's binary signed-in/unsubscribed full-screen paywall redirect with routing derived from the Worker's new 5-state `GET /api/billing/me` entitlement snapshot, and give the rest of the app (this plan's downstream consumers) a typed, reactive way to read that snapshot plus a typed set of client-facing entitlement-limit states.

**Architecture:** `RishiCore` gains a `EntitlementSnapshot` enum (custom `Decodable`, mirrors the Worker's flat JSON exactly) and a `BillingMeEndpoint` that decodes directly into it. `RishiBilling`'s existing `EntitlementService` actor — already the app's binary-entitlement source of truth via `currentLevel: AsyncStream<EntitlementLevel>` — becomes ALSO the snapshot's source of truth via a second, parallel `currentSnapshot: AsyncStream<EntitlementSnapshot>` (the two entitlement models stay side by side; see "Design decisions" #1). A new `@MainActor @Observable` `EntitlementSnapshotStore` bridges that actor stream into a plain value `RootView` and downstream SwiftUI views read via `@Environment`, following the exact same bridging shape `CustomerEntitlements`/`SubscriptionService` already use in this codebase. `RootView` drops its `SubscriptionsView` full-screen block entirely — every signed-in user (trial, paid, exhausted, or expired) now reaches `SignedInView`. `rishiApp.swift` gains one launch+foreground refresh hook. A new `EntitlementClientState` typed flag set (in `RishiBilling`) derives three of its six required cases from the snapshot alone and documents the other three as an explicit seam for a later, not-yet-written control-WebSocket plan.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI `@Observable`/`@Environment`, Swift Package Manager (local packages `RishiCore`, `RishiBilling`), the existing `WorkerClient`/`WorkerEndpoint` networking layer.

---

## Before you start: what this plan assumes already landed

This is **plan 12 of 16** in the pricing/trial-launch series. It depends on:

- **`docs/superpowers/plans/2026-07-17-billing-me-entitlement-snapshot.md`** ("Worker plan 5") — `GET /api/billing/me` now returns the flat superset JSON documented in that plan's "Exports for downstream plans": `{ premium, premiumUntil, state, ...state-specific fields }`, with `Cache-Control: private, max-age=30, must-revalidate` unchanged. This plan's `EntitlementSnapshot` Swift type is written against that exact contract, verbatim:
  - `"trial_active"` + `remainingCredits: number`
  - `"trial_exhausted"` (no extra fields)
  - `"reader_active" | "voice_active"` + `periodEnd: number` (epoch ms) + `remainingNarrationSeconds: number` + `remainingVoiceChatSeconds: number`
  - `"subscription_expired"` (no extra fields)
  - `premium`/`premiumUntil` are deprecated-but-present; this plan's new code never reads them.
- **`docs/superpowers/plans/2026-07-17-usage-ledger-schema.md`** and the `UserUsageLedger`/voice-session plans — not read in full here; irrelevant to the iOS client, which only ever calls `GET /api/billing/me`.
- **No "storekit-four-products" plan exists yet** in `apps/apple/docs/superpowers/plans/` as of this writing (confirmed by directory search) — this plan therefore adds the app's only launch/foreground entitlement-refresh hook and documents the coordination point in "Exports for downstream plans" so that plan reuses it instead of adding a second `scenePhase` observer.

## Facts established by reading the current iOS codebase (read before writing code)

- `RootView.swift` (`apps/apple/rishi/rishi/RootView.swift:103-120`) is the LIVE full-screen block: inside `.signedIn`, it switches on `subscriptionService.currentSubscription` (`SubscriptionService.swift`'s binary `.subscribed`/`.unsubscribed`) and renders `SubscriptionsView(color:groupId:)` full-screen for `.unsubscribed`. `subscriptionService` is fed only by `CurrentViewModifier.swift`'s `CustomerEntitlementsViewModifier`, which itself is only invoked from inside `SubscriptionsView.swift` via `.checkCustomerEntitlements()` — i.e. today's binary state is StoreKit-only and has nothing to do with the Worker at all. This plan removes the switch; `subscriptionService`/`SubscriptionsView` are left in place (still usable by a later plan's in-context upgrade sheet) but stop being RootView's default routing.
- `EntitlementLevel.swift` (`Packages/RishiBilling/Sources/RishiBilling/Models/EntitlementLevel.swift`) is a binary `.unsubscribed`/`.subscribed` enum keyed off on-device StoreKit product IDs. **Correction to this plan's brief:** this file lives in `RishiBilling`, not `RishiCore` — the brief's file path was approximate. It is a genuinely different, narrower concept than the new snapshot (device-side StoreKit status vs. the Worker's 5-state trial/paid/expired union) and this plan does not touch it or its call sites.
- `EntitlementService.swift` (`Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift`) is an `actor` already exposing exactly the AsyncStream-plus-synchronous-snapshot-accessor shape this plan needs to replicate: `public nonisolated let currentLevel: AsyncStream<EntitlementLevel>` (yields the cached value on init, then on every `setCached`/`refresh`/`clearCache`), `func refresh() async -> Result<EntitlementLevel, Error>` (hits `GetSessionEndpoint`, never clobbers the cache on failure), `func snapshot() -> EntitlementLevel` (synchronous read). This plan adds a second, parallel set of members (`currentSnapshot`, `refreshSnapshot()`, `snapshotNow()`) to the same actor rather than replacing anything — see "Design decisions" #1.
- `EntitlementService` is constructed in `ServiceGraphFactory.swift:330` (`let entitlementService = EntitlementService(workerClient: workerClient)`) but the resulting value is **never stored anywhere** — `BootstrappedServices`'s real initializer call at the bottom of the same function has no `entitlementService:` argument, and the struct's field is commented out (`AppDependencies.swift:148`, `//   let entitlementService: EntitlementService`). The only use of the local variable is a throwaway `let _ = await entitlementService.snapshot()` at line 341. This plan fixes that: adds the field, passes the value through, and adds the new snapshot store alongside it.
- `CurrentViewModifier.swift` shows the codebase's established "observe StoreKit/actor state, write into an `@Observable` sink" pattern (`CustomerEntitlementsViewModifier` writing into `SubscriptionService.saveSubscription`). `EntitlementReconciler.swift` and `ReaderAppEntitlementFlag.swift` show the sibling pattern this plan actually follows more closely: a small `@MainActor @Observable final class` that other code injects via `@Environment` and reads directly, with no protocol/binary-flag indirection.
- **Orphaned files, and why this plan does not revive them:** `AppGate.swift` (`Entitlements/AppGate.swift`) is a pure `resolve(...)` function keyed on the binary `EntitlementLevel`; it has no call sites anywhere in the app (confirmed by search) and predates the snapshot's 5-state model — reviving it would require bolting 5 states onto a type designed for 2, which is exactly the "narrower concept" mismatch this plan is avoiding elsewhere. `EntitlementServerBridge.swift` is fully commented out and its target method, `EntitlementReconciler.setServer(_:)`, no longer exists on the live `EntitlementReconciler` (confirmed by reading the current file — only `setOnDevice`/`reset`/`recompute` remain). Reviving the bridge would mean re-adding a `setServer(EntitlementLevel)` method and conflating the new 5-state snapshot into a 2-state reconciler, which is the same mismatch. **Decision: build fresh** — a new, small, purpose-built `EntitlementSnapshotStore` (see Task 4) that mirrors `EntitlementReconciler`'s shape (a plain `@MainActor @Observable` class injected via `@Environment`) without inheriting its binary assumptions. `AppGate.swift`/`EntitlementServerBridge.swift` are left untouched and undeleted — deleting orphaned files is out of this plan's scope.
- `WorkerClient`'s `JSONDecoder` has no custom `dateDecodingStrategy` (confirmed by reading `WorkerClient.swift`), and `VerifyReceiptAPI.swift`'s doc comment explicitly warns that changing the global decoder strategy would break other endpoints (naming `/api/billing/me` as one of them) that read `premiumUntil` as a plain ISO **string**. This plan's `EntitlementSnapshot` therefore decodes `periodEnd` as a plain `Int64` (epoch ms, exactly as the wire sends it) — no `Date` decoding strategy involved anywhere.
- `apps/apple/Packages/RishiCore` has an existing `Models/` folder (`Book.swift`, `User.swift`, `Position.swift`, etc.) and an existing `Endpoints/` folder with one `Foo API.swift` file per Worker route family (`AuthAPI.swift`, `AudioAPI.swift`, ...); a separate `RishiAPI` package holds ONLY that domain's tests (`@testable import RishiCore`) — the real endpoint/model code always lives in `RishiCore`. This plan follows that exact convention: new types go in `RishiCore/Models/EntitlementSnapshot.swift` and `RishiCore/Endpoints/BillingAPI.swift`.

## Design decisions

**1. `EntitlementService` becomes the source of truth for BOTH entitlement models, side by side — not merged.** The brief's own recommendation. `EntitlementLevel`/`currentLevel`/`refresh()`/`snapshot()` are untouched; `EntitlementSnapshot`/`currentSnapshot`/`refreshSnapshot()`/`snapshotNow()` are added as a second, independent set of members on the same actor. Merging them (e.g. deriving `EntitlementLevel` from `EntitlementSnapshot` or vice versa) would require deciding how a 5-state union collapses into a 2-state one with no clean answer (`trial_active` — subscribed or not? paid-but-expired — subscribed or not?) and was explicitly not asked for. Keeping the actor as the single class avoids yet another cross-actor bridge and reuses one `WorkerClient` reference.

**2. `EntitlementSnapshot` is a Swift `enum` with a custom `Decodable` init, not a `Codable` struct + computed enum.** The brief allows either. An `enum` is chosen because Swift's exhaustive `switch` is exactly the shape every consumer (RootView's routing, later "in-context upgrade prompt" plans, `EntitlementClientState.derived(from:)`) needs, and because the wire shape genuinely is a discriminated union (fields are present/absent depending on `state`) — modeling it as a struct would require every field to be `Optional`, silently reintroducing the "which fields are actually valid together" bug class an enum eliminates at compile time. The nested `PaidPeriod` struct (see Task 1) avoids duplicating the three-field decode logic between `reader_active` and `voice_active`.

**3. `EntitlementSnapshot` lives in `RishiCore`, not `RishiBilling`.** `RishiCore` has zero dependency on `RishiBilling` (confirmed: `RishiBilling`'s `Package.swift` depends on `RishiCore`; the reverse is not true and would be a circular dependency if attempted). Since the type is decoded directly as a `WorkerEndpoint.Response` and `RishiCore` is where every other endpoint's response type already lives (`GetSessionEndpoint.ProfileResponse`, `VerifyReceiptEndpoint.ResponseBody`, etc.), putting it there keeps the wire-contract types in one place and lets both `RishiBilling` (which already imports `RishiCore`) and the app target (which already imports `RishiCore` directly in `RootView.swift`) consume it without a new dependency edge.

**4. The full-screen redirect is REMOVED, not kept side-by-side with a flag.** The brief's suggested lower-risk alternative ("keep both temporarily side-by-side if that's genuinely lower-risk") is rejected here: `subscriptionService.currentSubscription` and the new snapshot answer different questions (on-device StoreKit vs. server trial/paid/expired), so "keeping both" would mean deciding which one wins when they disagree — exactly the ambiguity a binary redirect created in the first place, and precisely what both design docs say to stop doing ("Replace the binary signed-in subscription redirect..."). Confirmed via search that nothing else in the app depends on `RootView`'s specific switch statement (`subscriptionService`/`currentSubscription` are otherwise only read inside `SubscriptionService.swift` itself, `SubscriptionsView.swift`, and written by `CurrentViewModifier.swift`) — removing the switch is safe.

**5. The launch/foreground refresh hook lives in `rishiApp.swift`, gated on a stored session.** `@Environment(\.scenePhase)` is Apple's documented pattern for foreground detection and is declared directly on the `App`-conforming struct (not a `View`), matching `rishiApp`'s existing `.task { await deps.bootstrap() }` call site. The hook checks `Keychain.load(.userId) != nil` first — the same guard `RootView.realBodyContent`'s own bootstrap `.task` already uses before touching the network — so a fresh, genuinely signed-out install does not fire one guaranteed-401, log-spamming `/api/billing/me` call before the user has ever signed in.

**6. `EntitlementClientState` is a `Set`, not a single enum.** More than one of the six required states can be true at the same time in principle (e.g. paid narration exhausted while a Voice Chat session is still mid-warning). A `Set<EntitlementClientState>` lets `EntitlementSnapshotStore` publish "everything true right now" as one value without inventing a combinatorial enum. Three cases (`.trialExhaustion`, `.paidNarrationExhaustion`, `.paidVoiceChatExhaustion`) are pure functions of `EntitlementSnapshot` and are computed by `EntitlementClientState.derived(from:)`. The other three (`.voiceChatWarning`, `.terminalCap`, `.providerSetupFailure`) require the control-WebSocket `session_ending`/`session_ended`/`session_error` messages a LATER plan delivers (per the no-card-credit-trial-design spec's "Control WebSocket" section) — this plan defines a `setVoiceControlSignals(_:)` seam on `EntitlementSnapshotStore` that a later plan calls, and explicitly does not fabricate a stand-in signal source for them.

---

## File structure

| File | Change |
| --- | --- |
| `Packages/RishiCore/Sources/RishiCore/Models/EntitlementSnapshot.swift` | Create — the 5-state snapshot enum + custom `Decodable` |
| `Packages/RishiCore/Sources/RishiCore/Endpoints/BillingAPI.swift` | Create — `BillingMeEndpoint: WorkerEndpoint` |
| `Packages/RishiCore/Sources/RishiCore/RishiCore+API.swift` | Modify — index doc entry |
| `Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementClientState.swift` | Create — typed client-state flag set |
| `Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift` | Modify — add `currentSnapshot`/`refreshSnapshot()`/`snapshotNow()` |
| `Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementSnapshotStore.swift` | Create — `@MainActor @Observable` bridge |
| `Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift` | Modify — index doc entries |
| `rishi/rishi/AppDependencies.swift` | Modify — add two `BootstrappedServices` fields |
| `rishi/rishi/AppDependencies+Billing.swift` | Modify — add two forwarding computed vars |
| `rishi/rishi/ServiceGraphFactory.swift` | Modify — construct the store, pass both through |
| `rishi/rishi/RootView.swift` | Modify — remove the full-screen redirect, inject the store |
| `rishi/rishi/rishiApp.swift` | Modify — launch/foreground refresh hook |

No other files change. No test files are created or modified (explicit override).

---

### Task 1: `EntitlementSnapshot` type + `BillingMeEndpoint` (RishiCore)

**Files:**
- Create: `apps/apple/Packages/RishiCore/Sources/RishiCore/Models/EntitlementSnapshot.swift`
- Create: `apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/BillingAPI.swift`
- Modify: `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiCore+API.swift`

- [ ] **Step 1: Create the snapshot type**

Create `apps/apple/Packages/RishiCore/Sources/RishiCore/Models/EntitlementSnapshot.swift`:

```swift
import Foundation

/// Server-owned entitlement snapshot returned by `GET /api/billing/me`.
///
/// Mirrors the Worker's `EntitlementSnapshot` union exactly — see
/// `docs/superpowers/plans/2026-07-17-billing-me-entitlement-snapshot.md`'s
/// "Exports for downstream plans" for the authoritative wire contract this
/// type decodes. The wire response is a FLAT JSON object discriminated by a
/// top-level `"state"` string; it also carries two deprecated top-level
/// fields (`premium`, `premiumUntil`) that this type intentionally never
/// reads — new logic builds on `state` and its associated fields only.
///
/// `EntitlementLevel` (`RishiBilling`) is a different, narrower concept — the
/// on-device StoreKit entitlement status — and is untouched by this type.
public enum EntitlementSnapshot: Sendable, Equatable {
    case trialActive(remainingCredits: Int)
    case trialExhausted
    case readerActive(PaidPeriod)
    case voiceActive(PaidPeriod)
    case subscriptionExpired

    /// Fields shared by `reader_active` and `voice_active`. A separate type
    /// (rather than duplicating three properties on both enum cases) so
    /// `EntitlementSnapshot`'s `Decodable` init and any downstream code that
    /// only cares about "the current paid period" can share one shape.
    public struct PaidPeriod: Sendable, Equatable {
        /// Epoch milliseconds, exactly as the Worker emits it — no `Date`
        /// decoding strategy is involved anywhere in this type (see the
        /// plan's "Facts established by reading the current codebase" on
        /// why `WorkerClient`'s decoder must not gain one).
        public let periodEndMs: Int64
        public let remainingNarrationSeconds: Int
        public let remainingVoiceChatSeconds: Int

        public init(
            periodEndMs: Int64,
            remainingNarrationSeconds: Int,
            remainingVoiceChatSeconds: Int
        ) {
            self.periodEndMs = periodEndMs
            self.remainingNarrationSeconds = remainingNarrationSeconds
            self.remainingVoiceChatSeconds = remainingVoiceChatSeconds
        }

        /// Convenience `Date` for display code. Computed, not stored — the
        /// wire value stays the source of truth.
        public var periodEnd: Date {
            Date(timeIntervalSince1970: Double(periodEndMs) / 1000)
        }
    }

    /// `nil` for every case except the two paid-period cases. Convenience
    /// for display code that wants "when does this reset" without a
    /// `switch`.
    public var periodEnd: Date? {
        switch self {
        case .readerActive(let period), .voiceActive(let period):
            return period.periodEnd
        case .trialActive, .trialExhausted, .subscriptionExpired:
            return nil
        }
    }
}

// MARK: - Decodable

extension EntitlementSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case state
        case remainingCredits
        case periodEnd
        case remainingNarrationSeconds
        case remainingVoiceChatSeconds
    }

    private enum WireState: String, Decodable {
        case trialActive = "trial_active"
        case trialExhausted = "trial_exhausted"
        case readerActive = "reader_active"
        case voiceActive = "voice_active"
        case subscriptionExpired = "subscription_expired"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(WireState.self, forKey: .state)
        switch state {
        case .trialActive:
            let remaining = try container.decode(Int.self, forKey: .remainingCredits)
            self = .trialActive(remainingCredits: remaining)
        case .trialExhausted:
            self = .trialExhausted
        case .subscriptionExpired:
            self = .subscriptionExpired
        case .readerActive, .voiceActive:
            let period = PaidPeriod(
                periodEndMs: try container.decode(Int64.self, forKey: .periodEnd),
                remainingNarrationSeconds: try container.decode(
                    Int.self, forKey: .remainingNarrationSeconds
                ),
                remainingVoiceChatSeconds: try container.decode(
                    Int.self, forKey: .remainingVoiceChatSeconds
                )
            )
            self = (state == .readerActive) ? .readerActive(period) : .voiceActive(period)
        }
    }
}
```

- [ ] **Step 2: Create the endpoint**

Create `apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/BillingAPI.swift`:

```swift
import Foundation

/// `GET /api/billing/me` — the authoritative entitlement snapshot for the
/// signed-in user. See `EntitlementSnapshot` for the decoded shape and
/// `docs/superpowers/plans/2026-07-17-billing-me-entitlement-snapshot.md`
/// for the exact wire contract this mirrors.
///
/// The Worker sends `Cache-Control: private, max-age=30, must-revalidate`
/// on this response. This client layers no additional caching on top —
/// `RishiBilling.EntitlementService.refreshSnapshot()` decides when to call
/// this endpoint (launch, foreground; see that type and `rishiApp.swift`).
public struct BillingMeEndpoint: WorkerEndpoint {
    public typealias Response = EntitlementSnapshot

    public let method: HTTPMethod = .GET
    public let path: String = "/api/billing/me"

    public init() {}
}
```

- [ ] **Step 3: Add the index-doc entry**

In `apps/apple/Packages/RishiCore/Sources/RishiCore/RishiCore+API.swift`, find the `MARK: - Models / Types` block and add one line after the existing `User` line:

```swift
// User                        — `Models/User.swift`. The signed-in user (id, email, displayName, hasPro).
// EntitlementSnapshot         — `Models/EntitlementSnapshot.swift`. The 5-state server-owned
//                                entitlement union from `GET /api/billing/me` (trial_active /
//                                trial_exhausted / reader_active / voice_active /
//                                subscription_expired). Decoded by `Endpoints/BillingAPI.swift`'s
//                                `BillingMeEndpoint`. Consumed by RishiBilling.EntitlementService.
```

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiCore
swift test --package-path .
```

Expected: package builds and its existing test suite passes unchanged. `EntitlementSnapshot`/`BillingMeEndpoint` have no callers yet outside this task, so nothing else can regress.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/apple/Packages/RishiCore/Sources/RishiCore/Models/EntitlementSnapshot.swift apps/apple/Packages/RishiCore/Sources/RishiCore/Endpoints/BillingAPI.swift apps/apple/Packages/RishiCore/Sources/RishiCore/RishiCore+API.swift
git commit -m "feat(ios): add EntitlementSnapshot type and BillingMeEndpoint to RishiCore"
```

---

### Task 2: `EntitlementClientState` typed flag set (RishiBilling)

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementClientState.swift`

- [ ] **Step 1: Create the type**

Create `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementClientState.swift`:

```swift
import Foundation
import RishiCore

/// Typed client-facing entitlement-limit states, per both design docs'
/// "App and billing changes" list: trial exhaustion, paid narration
/// exhaustion, paid Voice Chat exhaustion, Voice Chat warning, terminal cap,
/// and provider setup failure.
///
/// Modeled as individual flags collected into a `Set` (see
/// `EntitlementSnapshotStore.clientStates`) rather than one enum, because
/// more than one can be true at the same time in principle — e.g. paid
/// narration exhausted while a live Voice Chat session is still mid-warning.
///
/// Three cases are pure functions of `EntitlementSnapshot` and are produced
/// by ``derived(from:)``. The other three — ``voiceChatWarning``,
/// ``terminalCap``, ``providerSetupFailure`` — require the control-WebSocket
/// `session_ending` / `session_ended` / `session_error` messages a LATER
/// plan delivers (see the no-card-credit-trial-design spec's "Control
/// WebSocket" section). `derived(from:)` never produces them; they reach
/// `EntitlementSnapshotStore.clientStates` only via
/// ``EntitlementSnapshotStore/setVoiceControlSignals(_:)``, a seam this
/// plan defines but does not call anywhere in production. Do not build a
/// stand-in signal source for them here.
public enum EntitlementClientState: String, Sendable, Equatable, CaseIterable {
    /// Derivable from `EntitlementSnapshot` alone: the account's snapshot
    /// `state` is exactly `.trialExhausted`.
    case trialExhaustion

    /// Derivable from `EntitlementSnapshot` alone: a `.readerActive` or
    /// `.voiceActive` snapshot whose `remainingNarrationSeconds <= 0`.
    case paidNarrationExhaustion

    /// Derivable from `EntitlementSnapshot` alone: a `.readerActive` or
    /// `.voiceActive` snapshot whose `remainingVoiceChatSeconds <= 0`.
    case paidVoiceChatExhaustion

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_ending` message via
    /// `setVoiceControlSignals(_:)`.
    case voiceChatWarning

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_ended` message via
    /// `setVoiceControlSignals(_:)`.
    case terminalCap

    /// SEAM — not derivable from the snapshot. Populated only by a later
    /// plan's control-WebSocket `session_error` message (or an OpenAI
    /// Realtime connection failure) via `setVoiceControlSignals(_:)`.
    case providerSetupFailure

    /// The three cases `setVoiceControlSignals(_:)` accepts. Any other case
    /// passed to that method is silently dropped — it is only a channel for
    /// the control-WebSocket-sourced signals, never a way to fake a
    /// snapshot-derived one.
    public static let voiceControlSeamCases: Set<EntitlementClientState> = [
        .voiceChatWarning, .terminalCap, .providerSetupFailure,
    ]

    /// The subset of states derivable purely from a snapshot, with no live
    /// voice-control signal involved. Called on every snapshot update — see
    /// `EntitlementSnapshotStore`.
    public static func derived(from snapshot: EntitlementSnapshot) -> Set<EntitlementClientState> {
        switch snapshot {
        case .trialExhausted:
            return [.trialExhaustion]
        case .trialActive, .subscriptionExpired:
            return []
        case .readerActive(let period), .voiceActive(let period):
            var states: Set<EntitlementClientState> = []
            if period.remainingNarrationSeconds <= 0 {
                states.insert(.paidNarrationExhaustion)
            }
            if period.remainingVoiceChatSeconds <= 0 {
                states.insert(.paidVoiceChatExhaustion)
            }
            return states
        }
    }
}
```

- [ ] **Step 2: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiBilling
swift test --package-path .
```

Expected: package builds and its existing test suite passes unchanged (this type has no callers yet).

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementClientState.swift
git commit -m "feat(ios): add EntitlementClientState typed flag set to RishiBilling"
```

---

### Task 3: Extend `EntitlementService` with the snapshot stream

**Files:**
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift`

- [ ] **Step 1: Add the doc-comment note and new stored properties**

Replace the file's opening doc comment and property block:

```swift
import Foundation
import RishiCore
import RishiLogging

/// Caches the user's current entitlement and exposes it as an `AsyncStream`.
///
/// BILL-01: Pro features check entitlement from `/api/auth/get-session`
/// (cached locally for offline UI). UI subscribes to ``currentLevel`` once at
/// view appearance; the service yields the cached value immediately, then
/// any further `refresh()` result.
///
/// Cache: `UserDefaults` under `"billing.entitlement.level"`. String rawValue
/// so missing / corrupt reads fall back to `.free` (safe default — never
/// silently grant Pro to a free user).
@available(iOS 18.4, *)
public actor EntitlementService {

    /// Continuous stream of entitlement values. The first subscriber always
    /// receives the hydrated cache immediately so SwiftUI bindings don't
    /// flicker offline. Each subsequent ``refresh()`` or ``setCached(_:)``
    /// yields exactly once when the value changes.
    public nonisolated let currentLevel: AsyncStream<EntitlementLevel>
    private let continuation: AsyncStream<EntitlementLevel>.Continuation

    private let workerClient: WorkerClient
    private let defaults: UserDefaults
    private var latest: EntitlementLevel

    /// UserDefaults key used for the cache. Stable contract — Plan 11-06
    /// references this key when wiring app launch hydration.
    public static let defaultsKey = "billing.entitlement.level"

    // MARK: - Server-owned entitlement snapshot (GET /api/billing/me)
    //
    // Added 2026-07-17 alongside the above. This is a SEPARATE, PARALLEL
    // entitlement model — `EntitlementLevel` (binary, on-device-StoreKit-
    // adjacent) and `EntitlementSnapshot` (the Worker's 5-state trial/paid/
    // expired union) answer different questions and are deliberately not
    // merged. See docs/superpowers/plans/2026-07-17-entitlement-snapshot-
    // client.md's "Design decisions" #1.

    /// Continuous stream of the server's entitlement snapshot. Unlike
    /// ``currentLevel``, this is NOT persisted to `UserDefaults` — there is
    /// no safe "last known" value that isn't itself stale, and the Worker's
    /// `Cache-Control: private, max-age=30, must-revalidate` header already
    /// governs staleness server-side. The first subscriber sees
    /// ``EntitlementSnapshot/trialExhausted`` (see ``latestSnapshot``'s doc
    /// comment) until the first ``refreshSnapshot()`` completes.
    public nonisolated let currentSnapshot: AsyncStream<EntitlementSnapshot>
    private let snapshotContinuation: AsyncStream<EntitlementSnapshot>.Continuation

    /// Safe placeholder until the first successful ``refreshSnapshot()``.
    /// `.trialExhausted` is chosen deliberately: it blocks AI-feature
    /// affordances (never show a Voice Chat / narration entry point before
    /// the server has actually confirmed an allowance) without blocking
    /// core reading, which per spec is never gated on entitlement state.
    private var latestSnapshot: EntitlementSnapshot = .trialExhausted

    public init(
        workerClient: WorkerClient,
        defaults: UserDefaults = .standard
    ) {
        self.workerClient = workerClient
        self.defaults = defaults

        // Hydrate from cache. Missing / unknown rawValue → .free.
        let cachedRaw = defaults.string(forKey: Self.defaultsKey)
        let cached = cachedRaw.flatMap(EntitlementLevel.init(rawValue:)) ?? .unsubscribed
        self.latest = cached

        var continuation: AsyncStream<EntitlementLevel>.Continuation!
        self.currentLevel = AsyncStream { c in continuation = c }
        self.continuation = continuation
        // Yield the cached value so any consumer subscribing immediately
        // after init sees a value without waiting for a refresh.
        continuation.yield(cached)

        var snapshotContinuation: AsyncStream<EntitlementSnapshot>.Continuation!
        self.currentSnapshot = AsyncStream { c in snapshotContinuation = c }
        self.snapshotContinuation = snapshotContinuation
        snapshotContinuation.yield(latestSnapshot)
    }
```

This replaces everything from the top of the file through the end of the existing `init` — every line inside the `init` body that already existed (the `EntitlementLevel` cache hydration + `currentLevel` stream setup) is preserved verbatim; only the new snapshot-stream setup is appended before the closing brace.

- [ ] **Step 2: Add `refreshSnapshot()`/`snapshotNow()` after the existing `snapshot()`**

The existing `setCached(_:)`, `refresh()`, `clearCache()`, and `snapshot()` methods (lines 58-103 of the original file) are UNCHANGED — leave them exactly where they are, immediately after the `init` from Step 1. Add the following new methods immediately after the existing `public func snapshot() -> EntitlementLevel { latest }`, before the actor's closing brace:

```swift

    // MARK: - Server-owned entitlement snapshot (continued)

    /// Hit `GET /api/billing/me` and update ``latestSnapshot``/``currentSnapshot``.
    /// Called at launch and foreground — see `rishiApp.swift`. Does not
    /// clobber ``latestSnapshot`` on failure, matching ``refresh()``'s
    /// "offline reads stay valid" contract. An unauthenticated caller (no
    /// stored session) fails here like any other network error; callers
    /// that only want to refresh for signed-in users must check that
    /// themselves first (see `rishiApp.swift`'s launch/foreground hook).
    @discardableResult
    public func refreshSnapshot() async -> Result<EntitlementSnapshot, Error> {
        do {
            let snapshot = try await workerClient.send(BillingMeEndpoint())
            latestSnapshot = snapshot
            snapshotContinuation.yield(snapshot)
            return .success(snapshot)
        } catch {
            Log.event(
                "billing.entitlement_snapshot.refresh_failed",
                level: .warning,
                data: ["error": String(describing: error)]
            )
            return .failure(error)
        }
    }

    /// Synchronous snapshot accessor, matching ``snapshot()``'s shape for
    /// the binary `EntitlementLevel` above.
    public func snapshotNow() -> EntitlementSnapshot { latestSnapshot }
}
```

- [ ] **Step 3: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiBilling
swift test --package-path .
```

Expected: package builds and its existing `EntitlementServiceTests` suite passes unchanged — every existing test exercises only `currentLevel`/`refresh()`/`setCached`/`snapshot()`/`clearCache()`, none of which changed behavior. `refreshSnapshot()`/`snapshotNow()`/`currentSnapshot` have no callers yet outside this task.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift
git commit -m "feat(ios): add EntitlementSnapshot stream to EntitlementService"
```

---

### Task 4: `EntitlementSnapshotStore` — the `@Observable` bridge

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementSnapshotStore.swift`
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`

- [ ] **Step 1: Create the store**

Create `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementSnapshotStore.swift`:

```swift
import Foundation
import Observation
import RishiCore

/// `@MainActor` bridge from `EntitlementService.currentSnapshot` (an actor's
/// `AsyncStream`) into a plain `@Observable` value SwiftUI can read and
/// switch on directly. Same bridging shape as `EntitlementReconciler` /
/// `ReaderAppEntitlementFlag`: a long-lived `Task` pumps the stream for the
/// app's lifetime and republishes on `@MainActor`.
///
/// `RootView` injects one instance into the environment
/// (`.environment(deps.services!.entitlementSnapshotStore)`); any downstream
/// view — including later plans' in-context upgrade prompts and
/// remaining-allowance UI — reads it via `@Environment(EntitlementSnapshotStore.self)`.
@available(iOS 18.4, *)
@MainActor
@Observable
public final class EntitlementSnapshotStore {

    public private(set) var snapshot: EntitlementSnapshot

    /// Union of `EntitlementClientState.derived(from: snapshot)` and
    /// whatever was last passed to ``setVoiceControlSignals(_:)``.
    public private(set) var clientStates: Set<EntitlementClientState>

    private var voiceControlSignals: Set<EntitlementClientState> = []
    private var pumpTask: Task<Void, Never>?

    public init(service: EntitlementService) {
        let initial: EntitlementSnapshot = .trialExhausted
        self.snapshot = initial
        self.clientStates = EntitlementClientState.derived(from: initial)

        let stream = service.currentSnapshot
        pumpTask = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.apply(value)
            }
        }
    }

    /// SEAM for a LATER plan (control-WebSocket delivery) to layer
    /// `.voiceChatWarning` / `.terminalCap` / `.providerSetupFailure` on top
    /// of the snapshot-derived states. Not called anywhere in production
    /// yet — see this plan's "Exports for downstream plans". Any case
    /// outside `EntitlementClientState.voiceControlSeamCases` passed here
    /// is silently dropped.
    public func setVoiceControlSignals(_ signals: Set<EntitlementClientState>) {
        voiceControlSignals = signals.intersection(EntitlementClientState.voiceControlSeamCases)
        recomputeClientStates()
    }

    private func apply(_ value: EntitlementSnapshot) {
        snapshot = value
        recomputeClientStates()
    }

    private func recomputeClientStates() {
        clientStates = EntitlementClientState.derived(from: snapshot).union(voiceControlSignals)
    }

    deinit {
        pumpTask?.cancel()
    }
}
```

- [ ] **Step 2: Update the index doc**

In `apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`, add a line to the `MARK: - Entitlement reconciliation` block, right after `StoreKitIAPFlag`:

```swift
// StoreKitIAPFlag             — `Entitlements/EntitlementReconciler.swift`. Namespace
//                                holding the kill-switch flag for StoreKit IAP.
// EntitlementSnapshotStore    — `Entitlements/EntitlementSnapshotStore.swift`. @MainActor
//                                @Observable bridge from EntitlementService.currentSnapshot;
//                                RootView and downstream views read `.snapshot`/`.clientStates`
//                                via @Environment.
// EntitlementClientState      — `Entitlements/EntitlementClientState.swift`. Typed flags: trial
//                                exhaustion, paid narration/Voice-Chat exhaustion (derivable from
//                                EntitlementSnapshot), plus Voice-Chat-warning/terminal-cap/
//                                provider-setup-failure seams a later plan populates.
```

- [ ] **Step 3: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiBilling
swift test --package-path .
```

Expected: package builds and its existing test suite passes unchanged.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/EntitlementSnapshotStore.swift apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift
git commit -m "feat(ios): add EntitlementSnapshotStore Observable bridge"
```

---

### Task 5: Wire the store through `BootstrappedServices`

**Files:**
- Modify: `apps/apple/rishi/rishi/AppDependencies.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Modify: `apps/apple/rishi/rishi/AppDependencies+Billing.swift`

- [ ] **Step 1: Add the two fields to `BootstrappedServices`**

In `apps/apple/rishi/rishi/AppDependencies.swift`, find:

```swift
    //   let entitlementService: EntitlementService
    //   let manageSubscriptionPresenter: ManageSubscriptionPresenter
    //    let storeKitProductService: StoreKitProductService
    //    let purchaseService: PurchaseService
    //   let transactionListener: TransactionListener
    let entitlementReconciler: EntitlementReconciler
```

Replace with:

```swift
    let entitlementService: EntitlementService
    let entitlementSnapshotStore: EntitlementSnapshotStore
    //   let manageSubscriptionPresenter: ManageSubscriptionPresenter
    //    let storeKitProductService: StoreKitProductService
    //    let purchaseService: PurchaseService
    //   let transactionListener: TransactionListener
    let entitlementReconciler: EntitlementReconciler
```

- [ ] **Step 2: Construct the store and pass both through**

In `apps/apple/rishi/rishi/ServiceGraphFactory.swift`, find:

```swift
        let entitlementService = EntitlementService(workerClient: workerClient)
        let _ = await MainActor.run {
            ManageSubscriptionPresenter()
        }
```

Replace with:

```swift
        let entitlementService = EntitlementService(workerClient: workerClient)
        let entitlementSnapshotStore = await MainActor.run {
            EntitlementSnapshotStore(service: entitlementService)
        }
        let _ = await MainActor.run {
            ManageSubscriptionPresenter()
        }
```

Then find the `return BootstrappedServices(...)` call near the end of the same function and, inside it, find:

```swift
            entitlementReconciler: reconciler,
```

Replace with:

```swift
            entitlementService: entitlementService,
            entitlementSnapshotStore: entitlementSnapshotStore,
            entitlementReconciler: reconciler,
```

(Leave the pre-existing `let _ = await entitlementService.snapshot()` line a few lines above untouched — it is unrelated dead code predating this plan and out of scope to clean up here.)

- [ ] **Step 3: Add forwarding computed vars**

In `apps/apple/rishi/rishi/AppDependencies+Billing.swift`, replace the full file:

```swift
import Foundation
import RishiBilling



extension AppDependencies {

    var entitlementService: EntitlementService { services!.entitlementService }
    var entitlementSnapshotStore: EntitlementSnapshotStore { services!.entitlementSnapshotStore }
    var entitlementReconciler: EntitlementReconciler { services!.entitlementReconciler }
    var readerAppEntitlementFlag: ReaderAppEntitlementFlag { services!.readerAppEntitlementFlag }
    var restoreService: RestoreService { services!.restoreService }
    var workerReceiptVerifier: any ReceiptVerifier { services!.workerReceiptVerifier }
}
```

- [ ] **Step 4: Verify**

The app target cannot be built with `xcodebuild` from a subagent (CLAUDE.md). Typecheck each touched file individually:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/AppDependencies.swift
xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/ServiceGraphFactory.swift
xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/AppDependencies+Billing.swift
```

Expected: each command reports errors ONLY about missing sibling app-target symbols it can't see in isolation (e.g. `BootstrappedServices`, `UserIdBox`, other services referenced from other files in the same target) — a single-file `swiftc -typecheck` cannot resolve cross-file symbols within one app target and this is a known limitation of this fallback command (per CLAUDE.md, the MAIN orchestrator's later full `xcodebuild` is the canonical gate, not this command). Confirm specifically that no error mentions `EntitlementSnapshotStore`, `entitlementService`, or `entitlementSnapshotStore` as an *undefined type/member* in a way that differs from how it already treats other, pre-existing sibling-file symbols (e.g. `EntitlementReconciler`) — if `EntitlementReconciler` produces the same class of error as `EntitlementSnapshotStore` does, that confirms the errors are the expected cross-file limitation and not something this task introduced.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/AppDependencies+Billing.swift
git commit -m "feat(ios): wire EntitlementSnapshotStore into BootstrappedServices"
```

---

### Task 6: `RootView` — remove the full-screen redirect, inject the store

**Files:**
- Modify: `apps/apple/rishi/rishi/RootView.swift`

- [ ] **Step 1: Remove the unused `subscriptionService` environment read**

Find:

```swift
    @Environment(SubscriptionService.self) private var subscriptionService

    
    private func realBodyContent(deps: AppDependencies) -> some View {
```

Replace with:

```swift
    private func realBodyContent(deps: AppDependencies) -> some View {
```

- [ ] **Step 2: Replace the binary switch with a direct `SignedInView()`**

Find:

```swift
            case .signedIn(user: _):
                switch subscriptionService.currentSubscription {
                case .subscribed(subscription: _):
                    SignedInView()
                case .unsubscribed:
                    if let groupID = deps.services?.groupID {

                        SubscriptionsView(color: .rishiBrown, groupId: groupID)

                    } else {
                        #if DEBUG
                            Text("GroupId not configured")
                        #endif
                        ProgressView()

                    }

                }

            }
```

Replace with:

```swift
            case .signedIn(user: _):
                // Per spec ("Replace the binary signed-in subscription
                // redirect with server-derived routing"): every signed-in
                // user — trial, paid, exhausted, or expired — reaches
                // SignedInView. AI-feature-specific upgrade prompts for
                // exhausted/expired users are a later plan's job, built on
                // the EntitlementSnapshotStore injected below.
                SignedInView()

            }
```

- [ ] **Step 3: Inject the snapshot store into the environment**

Find:

```swift
    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {

        realBodyContent(deps: deps)
            .environment(\.services, deps.services)

            .environment(
```

Replace with:

```swift
    @ViewBuilder
    private func realBody(deps: AppDependencies) -> some View {

        realBodyContent(deps: deps)
            .environment(\.services, deps.services)
            .environment(deps.services!.entitlementSnapshotStore)

            .environment(
```

(`deps.services!` is safe here — `body`, above, only calls `realBody(deps:)` when `deps.services != nil`, and every other call site inside this same function already force-unwraps `deps.services!`, e.g. the `OnboardingHost(services: deps.services!, ...)` call further down.)

- [ ] **Step 4: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/RootView.swift
```

Expected: same class of cross-file-symbol errors as Task 5 Step 4 (this is a single app-target file referencing many siblings) — confirm no error is specific to `SignedInView()` losing an argument it used to need, `entitlementSnapshotStore` being unresolved as a *member of `BootstrappedServices`* (as opposed to `BootstrappedServices` itself being unresolved in isolation), or `subscriptionService`/`SubscriptionsView` still being referenced anywhere in the file (grep the file for both strings — expect zero matches for `subscriptionService`, and confirm `SubscriptionsView` no longer appears either).

```bash
grep -n "subscriptionService\|SubscriptionsView" apps/apple/rishi/rishi/RootView.swift
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/rishi/rishi/RootView.swift
git commit -m "feat(ios): remove full-screen subscription redirect, route via EntitlementSnapshotStore"
```

---

### Task 7: Launch + foreground refresh hook

**Files:**
- Modify: `apps/apple/rishi/rishi/rishiApp.swift`

- [ ] **Step 1: Add the `scenePhase` environment read**

Find:

```swift
@main
struct rishiApp: App {
    @State private var deps = AppDependencies()
    @State private var router = AppRouter()
  
    var currentUserBox = CurrentUserBox()
```

Replace with:

```swift
@main
struct rishiApp: App {
    @State private var deps = AppDependencies()
    @State private var router = AppRouter()

    @Environment(\.scenePhase) private var scenePhase

    var currentUserBox = CurrentUserBox()
```

- [ ] **Step 2: Refresh at launch, add the foreground hook, add the helper**

Find:

```swift
                .task {
                    await deps.bootstrap()
                }
                .task {
                    // Configure and load your tips at app launch.
```

Replace with:

```swift
                .task {
                    await deps.bootstrap()
                    await refreshEntitlementSnapshot()
                }
                .task {
                    // Configure and load your tips at app launch.
```

Find the closing of `body`'s `WindowGroup { ... }` and the following `.commands { ... }`:

```swift
        }

        .commands {
            RishiMenuCommands(
                router: deps.macCommandRouter,
                account: deps.macAccountMenu
            )
        }
    }
}
```

Replace with:

```swift
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refreshEntitlementSnapshot() }
        }
        .commands {
            RishiMenuCommands(
                router: deps.macCommandRouter,
                account: deps.macAccountMenu
            )
        }
    }

    /// Launch/foreground entitlement-snapshot refresh, per both specs'
    /// "The client performs entitlement sync at launch, foreground...".
    /// Guards on a stored session so a genuinely signed-out fresh install
    /// does not fire one guaranteed-401, log-spamming `/api/billing/me`
    /// call before the user has ever signed in — the same
    /// `Keychain.load(.userId)` check `RootView.realBodyContent`'s own
    /// bootstrap `.task` already uses.
    ///
    /// Coordination note for a later "storekit-four-products" plan (does
    /// not exist yet as of this writing): if that plan also needs a
    /// launch/foreground hook — e.g. to sync StoreKit transactions — reuse
    /// THIS hook rather than adding a second `.onChange(of: scenePhase)`.
    /// See this plan's "Exports for downstream plans".
    private func refreshEntitlementSnapshot() async {
        guard (try? Keychain.load(.userId)) != nil else { return }
        await deps.entitlementService.refreshSnapshot()
    }
}
```

- [ ] **Step 3: Verify**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/rishiApp.swift
```

Expected: same class of cross-file-symbol errors as Task 5/6 (RishiAppDelegate, AppDependencies, etc. are defined in sibling files). Confirm no error is specific to `scenePhase`, `refreshEntitlementSnapshot`, or `Keychain.load` — those are either SwiftUI/Foundation/RishiCore symbols already resolvable in isolation, or a new private method with no external dependency.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/rishi/rishi/rishiApp.swift
git commit -m "feat(ios): add launch/foreground entitlement-snapshot refresh hook"
```

---

### Task 8: Final whole-scope verification

**Files:** none (verification only)

- [ ] **Step 1: Full package verification**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiCore
swift test --package-path .
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple/Packages/RishiBilling
swift test --package-path .
```

Expected: both packages' full existing test suites pass, with zero new tests added (explicit override) and zero regressions in existing `EntitlementServiceTests`/`EntitlementReconcilerTests`/etc.

- [ ] **Step 2: Confirm no dangling reference to the removed redirect**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
grep -rn "subscriptionService" apps/apple/rishi/rishi/RootView.swift
grep -rn "SubscriptionsView" apps/apple/rishi/rishi/RootView.swift
```

Expected: no output from either command.

- [ ] **Step 3: Hand off to the main orchestrator for the integrated build gate**

Per CLAUDE.md, only the MAIN orchestrator (not a subagent) runs the canonical `xcodebuild` check. Report this plan's file list (see "File structure" above) so the orchestrator can run:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/apple
xcodebuild -scheme rishi -destination 'generic/platform=iOS Simulator' build
```

and confirm zero new errors/warnings attributable to any file this plan touched.

- [ ] **Step 4: Commit (only if Steps 1-3 surfaced a fixup)**

If everything already committed cleanly in Tasks 1-7, there is nothing new to commit here.

---

## Self-review against the two spec documents and this plan's own scope

- **"Authoritative entitlement model"** (5 states, snapshot fields) → `EntitlementSnapshot` (Task 1) models all 5 states with exactly the fields the Worker plan's "Exports for downstream plans" locked in; no extra/missing fields.
- **"App and billing changes" — binary redirect replacement** → Task 6 removes the `SubscriptionsView` full-screen block entirely; every signed-in state reaches `SignedInView`. Confirmed via Task 6 Step 4/Task 8 Step 2 that no dangling reference remains.
- **"App and billing changes" — typed client states** → Task 2's `EntitlementClientState` covers all six named states (trial exhaustion, paid narration exhaustion, paid Voice Chat exhaustion, Voice Chat warning, terminal cap, provider setup failure), with the three snapshot-derivable ones actually computed and the other three left as an explicit, documented seam (`setVoiceControlSignals(_:)`) rather than faked.
- **"The client performs entitlement sync at launch, foreground..."** → Task 7's `rishiApp.swift` hook. Purchase-completion/restore/StoreKit-transaction-update sync triggers are explicitly out of this plan's scope (owned by the not-yet-written StoreKit/purchase plans in this series) — this plan only adds the launch/foreground half and documents the coordination point for a later plan to reuse.
- **"The iOS app uses it for routing and display only"** → confirmed: nothing in this plan writes back to the Worker or mutates ledger state; `EntitlementSnapshotStore` is read-only from the app's perspective (its only mutators are the internal stream pump and the documented `setVoiceControlSignals(_:)` seam).
- **Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N" language anywhere above; every code step shows complete before/after code including the one intentionally-unchanged method block in Task 3 Step 2 (explicitly called out as unchanged, not silently omitted).
- **Type consistency:** `EntitlementSnapshot`, `EntitlementSnapshot.PaidPeriod`, `BillingMeEndpoint`, `EntitlementClientState`, `EntitlementSnapshotStore`, `entitlementService`, `entitlementSnapshotStore` are spelled identically everywhere they appear across Tasks 1-7.

---

## Exports for downstream plans

### `EntitlementSnapshot` (from `RishiCore`, `Models/EntitlementSnapshot.swift`)

```swift
public enum EntitlementSnapshot: Sendable, Equatable {
    case trialActive(remainingCredits: Int)
    case trialExhausted
    case readerActive(PaidPeriod)
    case voiceActive(PaidPeriod)
    case subscriptionExpired

    public struct PaidPeriod: Sendable, Equatable {
        public let periodEndMs: Int64
        public let remainingNarrationSeconds: Int
        public let remainingVoiceChatSeconds: Int
        public var periodEnd: Date { get }
    }

    public var periodEnd: Date? { get }
}
```

Decodes directly from `GET /api/billing/me`'s flat JSON via `BillingMeEndpoint` (`RishiCore`, `Endpoints/BillingAPI.swift`, `WorkerEndpoint.Response = EntitlementSnapshot`). `premium`/`premiumUntil` deprecated fields on the wire are never read by this type.

### How downstream views read the current snapshot

`EntitlementSnapshotStore` (`RishiBilling`, `Entitlements/EntitlementSnapshotStore.swift`) is injected into the environment once, in `RootView.realBody(deps:)`:

```swift
.environment(deps.services!.entitlementSnapshotStore)
```

Any downstream SwiftUI view reads it exactly like `EntitlementReconciler`/`ReaderAppEntitlementFlag`:

```swift
@Environment(EntitlementSnapshotStore.self) private var entitlementStore

// entitlementStore.snapshot: EntitlementSnapshot        — switch on this for full-state UI
// entitlementStore.clientStates: Set<EntitlementClientState> — check membership for limit banners
```

For non-view code (services, presenters) that already holds a `BootstrappedServices`/`AppDependencies` reference, the same instance is reachable via `services.entitlementSnapshotStore` / `deps.entitlementSnapshotStore` (`AppDependencies+Billing.swift`). The underlying actor is `services.entitlementService` / `deps.entitlementService`, exposing `refreshSnapshot()` (async, call after a purchase/restore/StoreKit-transaction-update completes — NOT built by this plan, but this is the exact method a later StoreKit plan should call) and `snapshotNow()` (synchronous read).

### `EntitlementClientState` (from `RishiBilling`, `Entitlements/EntitlementClientState.swift`)

```swift
public enum EntitlementClientState: String, Sendable, Equatable, CaseIterable {
    case trialExhaustion          // snapshot-derivable
    case paidNarrationExhaustion  // snapshot-derivable
    case paidVoiceChatExhaustion  // snapshot-derivable
    case voiceChatWarning         // SEAM — control-WebSocket `session_ending`
    case terminalCap              // SEAM — control-WebSocket `session_ended`
    case providerSetupFailure     // SEAM — control-WebSocket `session_error` / Realtime failure

    public static let voiceControlSeamCases: Set<EntitlementClientState>
    public static func derived(from snapshot: EntitlementSnapshot) -> Set<EntitlementClientState>
}
```

A later plan (the not-yet-written control-WebSocket plan) should, on receiving `session_ending`/`session_ended`/`session_error` over its WebSocket client, call:

```swift
entitlementSnapshotStore.setVoiceControlSignals([.voiceChatWarning])   // on session_ending
entitlementSnapshotStore.setVoiceControlSignals([.terminalCap])        // on session_ended
entitlementSnapshotStore.setVoiceControlSignals([.providerSetupFailure]) // on session_error
entitlementSnapshotStore.setVoiceControlSignals([])                    // clear, on a fresh non-terminal snapshot
```

No production code calls `setVoiceControlSignals(_:)` as of this plan — it exists solely as this seam.

### App-lifecycle refresh hook coordination point

`rishiApp.swift` (Task 7) now owns the app's ONLY `@Environment(\.scenePhase)` observer, gated on `Keychain.load(.userId) != nil`, calling `deps.entitlementService.refreshSnapshot()` at launch (inside the existing `.task { await deps.bootstrap() }`) and on every foreground transition (`.onChange(of: scenePhase)` → `.active`). A later "storekit-four-products" plan that needs its own launch/foreground sync (e.g. `AppStore.sync()` or a StoreKit-transaction re-check) should add its call inside `refreshEntitlementSnapshot()` (or call it from the same two call sites) rather than adding a second `scenePhase` observer, to avoid two independent hooks firing redundant work on every foreground event.

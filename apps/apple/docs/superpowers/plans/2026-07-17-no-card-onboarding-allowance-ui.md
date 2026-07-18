# No-Card Onboarding, Remaining-Allowance UI, and Exhaustion Upgrade Prompts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Testing note (explicit override):** This plan intentionally SKIPS writing or running automated tests. Verify each step by compiling only: `swift test --package-path apps/apple/Packages/<Package>` for a touched Swift package (builds the package + its existing test target without requiring new tests), or `xcrun --sdk iphonesimulator swiftc -typecheck <file>` for a touched file under `apps/apple/rishi/rishi/`. Per `apps/apple/CLAUDE.md`, do NOT run `xcodebuild rishi` from a subagent.
>
> **Execution order:** this is **plan 13 of 16** in the pricing/trial-launch series and hard-depends on **plan 12, `2026-07-17-entitlement-snapshot-client.md`, having already landed** — it consumes that plan's `EntitlementSnapshot` (RishiCore), `EntitlementSnapshotStore` (RishiBilling), and `BootstrappedServices.entitlementSnapshotStore`/`AppDependencies.entitlementSnapshotStore` verbatim (see "Upstream dependency — resolved" below). Do not execute this plan before plan 12's Task 8 (final verification) is complete.

**Goal:** Give the no-card trial and paid plans (spec: `2026-07-17-no-card-credit-trial-design.md`, `2026-07-17-rishi-pricing-trial-launch-prerequisites-design.md`) their client-facing UI: a one-time no-card onboarding explainer, a remaining-allowance display that never leaks raw credits to paid users, and a non-blocking upgrade prompt shown exactly at the two AI-feature entry points (Read Aloud, Voice Chat) when the account has no allowance left.

**Architecture:** Three independent, additive UI surfaces reusing existing package boundaries — `RishiOnboarding` gets a new one-time, per-account screen; `RishiBilling` gets the allowance-derived views plus a pure exhaustion-check extension on plan 12's `EntitlementSnapshot`; the app target wires the onboarding trigger into `RootView` and the two upgrade-prompt interception points into the existing `ReaderDestination.swift` (TTS) and `ReaderVoiceEntry.swift` (Voice Chat) seams that already exist for this exact purpose (see the `2026-06-19-metered-free-taste-paywall-design.md` precedent — `onRequestPaywall` already bubbles from `ReaderDestination` up to `LibraryTabView`'s `model.requestPaywall`). Every consuming call site reads the already-live `EntitlementSnapshotStore` that plan 12 injected — there is no deferred/placeholder wiring in this plan.

**Tech Stack:** SwiftUI, Swift 6 strict concurrency, `@Observable`, `UserDefaults` (no GRDB/SwiftData needed — all new persistence is a handful of scalar flags).

---

## Upstream dependency — resolved

`apps/apple/docs/superpowers/plans/2026-07-17-entitlement-snapshot-client.md` (plan 12) now exists and has already built everything this plan needs. Its "Exports for downstream plans" section is the authority; summarized here for this plan's own tasks:

- **`EntitlementSnapshot`** — `RishiCore/Sources/RishiCore/Models/EntitlementSnapshot.swift`. A Swift `enum`, NOT a struct with optional fields:

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

      public var periodEnd: Date? { get }   // nil except the two paid-period cases
  }
  ```

- **`EntitlementSnapshotStore`** — `RishiBilling/Sources/RishiBilling/Entitlements/EntitlementSnapshotStore.swift`. `@MainActor @Observable public final class` (no `@available` gate) with `public private(set) var snapshot: EntitlementSnapshot` and `public private(set) var clientStates: Set<EntitlementClientState>`. Already injected into the SwiftUI environment by `RootView.realBody(deps:)` (`.environment(deps.services!.entitlementSnapshotStore)`) and reachable from non-view code as `services.entitlementSnapshotStore` / `deps.entitlementSnapshotStore` (`BootstrappedServices` / `AppDependencies+Billing.swift`).
- **`EntitlementClientState`** — `RishiBilling/Sources/RishiBilling/Entitlements/EntitlementClientState.swift`. Already provides `.trialExhaustion` / `.paidNarrationExhaustion` / `.paidVoiceChatExhaustion` (derived from the snapshot) plus three control-WebSocket seam cases this plan does not touch.

This plan's original draft (written before plan 12 existed) assumed a struct-shaped snapshot living in `RishiBilling` with an optional-closure, nil-defaulted access pattern for safety. That assumption is **replaced** below by the real enum + the real, always-live `EntitlementSnapshotStore` — every task that follows reads the live store directly; there is no `{ nil }`-defaulted deferred-integration seam anywhere in this version of the plan.

None of this plan's own new types collide with plan 12's: `AIFeature`, `AIFeatureBlockReason`, `blockReason(for:)`, `AllowanceFormatter`, `RemainingAllowanceView`, `AIFeatureUpgradePrompt`, and the onboarding flag store are all new and wholly owned by this plan.

---

## File plan

| File | Package | Change |
| --- | --- | --- |
| `Sources/RishiOnboarding/Storage/TrialOnboardingState.swift` | RishiOnboarding | Create — per-account "seen no-card intro" flag |
| `Sources/RishiOnboarding/UI/NoCardTrialScreen.swift` | RishiOnboarding | Create — the one-time explainer screen |
| `Sources/RishiOnboarding/RishiOnboarding+API.swift` | RishiOnboarding | Modify — index the two new exports |
| `Sources/RishiBilling/Entitlements/AIFeatureGate.swift` | RishiBilling | Create — `AIFeature` / `AIFeatureBlockReason` / `EntitlementSnapshot.blockReason(for:)` |
| `Sources/RishiBilling/UI/AllowanceFormatter.swift` | RishiBilling | Create — pure formatting + warning-threshold helpers |
| `Sources/RishiBilling/UI/RemainingAllowanceView.swift` | RishiBilling | Create — the credit-counter / time-remaining component |
| `Sources/RishiBilling/UI/AIFeatureUpgradePrompt.swift` | RishiBilling | Create — the exhaustion upgrade-prompt sheet |
| `Sources/RishiBilling/RishiBilling+API.swift` | RishiBilling | Modify — index the four new exports |
| `Sources/RishiSettings/UI/Billing/BillingSection.swift` | RishiSettings | Modify — render `RemainingAllowanceView` above the manage-subscription row |
| `Sources/RishiSettings/UI/SettingsScreen.swift` | RishiSettings | Modify — thread an optional `entitlementSnapshot` through to `BillingSection` |
| `apps/apple/rishi/rishi/Settings/SettingsContent.swift` | app target | Modify — pass the live `services.entitlementSnapshotStore.snapshot` into `SettingsScreen` |
| `apps/apple/rishi/rishi/AppDependencies.swift` | app target | Modify — add `trialOnboardingState` to `BootstrappedServices` |
| `apps/apple/rishi/rishi/AppDependencies+Settings.swift` | app target | Modify — expose `deps.trialOnboardingState` |
| `apps/apple/rishi/rishi/ServiceGraphFactory.swift` | app target | Modify — construct `UserDefaultsTrialOnboardingState()` |
| `apps/apple/rishi/rishi/RootView.swift` | app target | Modify — trigger `NoCardTrialScreen` once per account after the existing wizard onboarding |
| `apps/apple/rishi/rishi/Reader/ReaderDestination.swift` | app target | Modify — gate the TTS play button + present the Voice Chat exhaustion sheet |
| `apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift` | app target | Modify — gate `presentVoice` at its single choke point |

No `Package.swift` changes are needed anywhere — `RishiOnboarding` already depends on `RishiCore` (for `UserID`), `RishiBilling`/`RishiSettings` already depend on each other correctly, and the app target already imports both.

---

### Task 1: Per-account "seen no-card intro" flag

**Files:**
- Create: `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/Storage/TrialOnboardingState.swift`

The existing `OnboardingState` (`Storage/OnboardingState.swift`) is device-scoped (`"onboarding.completed"`, no user ID) — correct for "have I ever run the first-run wizard on this device," wrong for "has *this account* seen the no-card trial explainer," which must follow the account across devices/reinstalls-with-restore and must not leak to a second account signed into the same device. Follow the exact per-account keying pattern already used by `UserDefaultsTTSSettingsStore` (`RishiAudio/Sources/RishiAudio/Settings/TTSSettingsStore.swift:26-52`): one `UserDefaults` key per user, built from `UserID.uuidString`.

- [ ] **Step 1: Create the protocol + UserDefaults + in-memory implementations**

```swift
import Foundation
import RishiCore

/// Persisted per-account "has this account seen the no-card trial explainer"
/// flag. Deliberately separate from `OnboardingState` (device-scoped, no
/// user ID) because the no-card explainer is about an *account's* trial
/// entitlement, not this *device's* first-run wizard: a second account
/// signing in on the same device must see it again, and the same account
/// restoring on a new device must not.
public protocol TrialOnboardingState: Sendable {
    func hasSeenNoCardIntro(userId: UserID) async -> Bool
    func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async
}

/// UserDefaults-backed implementation. Key pattern matches
/// `UserDefaultsTTSSettingsStore.key(for:)` — `"<namespace>.<userId>"`.
///
/// @unchecked Sendable justified: holds `let defaults: UserDefaults`, which
/// is non-Sendable under Swift 6 strict concurrency despite Apple's documented
/// thread safety for the scalar accessors used here. Mirrors the same pattern
/// as `UserDefaultsOnboardingState` / `UserDefaultsTTSSettingsStore`.
public final class UserDefaultsTrialOnboardingState: TrialOnboardingState, @unchecked Sendable {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasSeenNoCardIntro(userId: UserID) async -> Bool {
        defaults.bool(forKey: Self.key(for: userId))
    }

    public func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async {
        defaults.set(value, forKey: Self.key(for: userId))
    }

    static func key(for userId: UserID) -> String {
        "onboarding.noCardTrial.seen.\(userId.uuidString)"
    }
}

/// Test/preview-only in-memory implementation.
public actor InMemoryTrialOnboardingState: TrialOnboardingState {
    private var seen: Set<UserID> = []

    public init() {}

    public func hasSeenNoCardIntro(userId: UserID) async -> Bool {
        seen.contains(userId)
    }

    public func setHasSeenNoCardIntro(_ value: Bool, userId: UserID) async {
        if value { seen.insert(userId) } else { seen.remove(userId) }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift test --package-path apps/apple/Packages/RishiOnboarding`
Expected: builds clean (existing `RishiOnboardingTests` target still passes — this step adds no test).

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/Storage/TrialOnboardingState.swift
git commit -m "Add per-account no-card trial intro flag storage"
```

---

### Task 2: No-card trial explainer screen

**Files:**
- Create: `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/UI/NoCardTrialScreen.swift`
- Modify: `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/RishiOnboarding+API.swift`

Mirror `FirstReaderHint.swift` and `WelcomeScreen.swift` exactly: `RishiScreenScaffold(actionPlacement: .pinnedToBottom)`, `RishiTypography`/`RishiColor`/`RishiSpacing` tokens, one primary button, an `accessibilityIdentifier`, a `#Preview`. Content covers the three product facts from the spec's "App and billing changes" section: no card required, the 100-credit starter allowance (non-expiring), and a one-line usage explainer (1 credit per narrated passage, 2 credits per 30 seconds of Voice Chat) so a new user understands what "credits" mean before ever seeing a counter.

- [ ] **Step 1: Create the screen**

```swift
import SwiftUI
import RishiUIKit

/// One-time, per-account explainer shown after first sign-in, before any
/// entitlement UI. Persistence: `TrialOnboardingState` (per-account, not
/// per-device — see `Storage/TrialOnboardingState.swift`).
///
/// Deliberately separate from `OnboardingFlowView`'s device-scoped wizard
/// stages: this screen depends on knowing *which account* signed in, so it
/// is triggered from the app shell (`RootView`) once `CurrentUserBox` has a
/// signed-in user, not from `OnboardingCoordinator`.
public struct NoCardTrialScreen: View {
    public let onGotIt: () -> Void

    public init(onGotIt: @escaping () -> Void) {
        self.onGotIt = onGotIt
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "gift.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text("Try Rishi's AI features free")
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: RishiSpacing.m) {
                    bullet(
                        icon: "creditcard.slash.fill",
                        text: "No credit card required"
                    )
                    bullet(
                        icon: "bolt.fill",
                        text: "100 free credits to start — they never expire"
                    )
                    bullet(
                        icon: "waveform",
                        text: "Credits cover Natural AI narration and Voice Chat. Reading your books is always free."
                    )
                }
                .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            Button(action: onGotIt) {
                Text("Got it")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RishiSpacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(RishiColor.accent)
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
            .accessibilityIdentifier("onboarding-no-card-trial-gotit")
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: RishiSpacing.s) {
            Image(systemName: icon)
                .foregroundStyle(RishiColor.accent)
                .frame(width: 20)
            Text(text)
                .font(RishiTypography.body)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}

#Preview {
    NoCardTrialScreen(onGotIt: {})
}
```

- [ ] **Step 2: Index the new exports**

Add to `apps/apple/Packages/RishiOnboarding/Sources/RishiOnboarding/RishiOnboarding+API.swift`, after the existing `OnboardingFlowView` line under `MARK: - Views`:

```swift
// NoCardTrialScreen             — `UI/NoCardTrialScreen.swift`. One-time,
//                                per-account "100 free credits, no card"
//                                explainer shown after first sign-in.
```

And after the `OnboardingState` / `UserDefaultsOnboardingState` lines under `MARK: - Storage`:

```swift
// TrialOnboardingState         — `Storage/TrialOnboardingState.swift`. Protocol.
//                                Has this ACCOUNT (not device) seen the no-card
//                                trial explainer?
// UserDefaultsTrialOnboardingState
//                              — `Storage/TrialOnboardingState.swift`. Production
//                                implementation, keyed by `UserID`.
```

- [ ] **Step 3: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiOnboarding`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiOnboarding
git commit -m "Add no-card trial explainer screen"
```

---

### Task 3: The AI-feature exhaustion gate

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/AIFeatureGate.swift`

The seam every remaining task in this plan (4 through 10) builds on: a **pure, synchronous, side-effect-free** function, `EntitlementSnapshot.blockReason(for:)`, answering "should this AI feature tap be intercepted right now, and why?" That purity is intentional — it is the exact function the `voice-session-flow-wiring` plan needs to call *before* opening a Voice Chat session (see "Exports for downstream plans" at the end of this document). It is a plain extension on plan 12's real `EntitlementSnapshot` enum (`RishiCore`) — this plan adds no new snapshot type.

`blockReason(for:)` never touches `remainingCredits` outside the two trial cases, and never touches `PaidPeriod`'s fields outside the two paid-plan cases — this is the mechanism (shared with `RemainingAllowanceView`, Task 5) that keeps "never expose paid internal credits to a paid-plan user" true by construction rather than by convention.

- [ ] **Step 1: Create the gate**

```swift
import Foundation
import RishiCore

/// The two AI features that can be gated at their entry point. Deliberately
/// does not include "reading" — core reading is never gated (spec: "core
/// reading remains available" at both `trialExhausted` and
/// `subscriptionExpired`).
public enum AIFeature: Sendable, Equatable {
    case narration
    case voiceChat
}

/// Why an AI-feature tap was intercepted. `Identifiable` so it can drive
/// `.sheet(item:)` directly (see `AIFeatureUpgradePrompt`, `ReaderDestination`,
/// `ReaderVoiceEntry`).
///
/// `.trialExhausted` / `.narrationAllowanceExhausted` / `.voiceChatAllowanceExhausted`
/// correspond 1:1 to `EntitlementClientState.trialExhaustion` /
/// `.paidNarrationExhaustion` / `.paidVoiceChatExhaustion` (plan 12) — this
/// type exists separately only to carry the fourth, feature-independent
/// `.subscriptionExpired` case and UI-facing copy (see `AIFeatureUpgradePrompt`),
/// not because the underlying signal differs.
public enum AIFeatureBlockReason: String, Sendable, Equatable, Identifiable {
    case trialExhausted
    case subscriptionExpired
    case narrationAllowanceExhausted
    case voiceChatAllowanceExhausted

    public var id: String { rawValue }
}

public extension EntitlementSnapshot {

    /// Pure, synchronous, side-effect-free access check for one AI feature.
    /// Returns `nil` when the feature should proceed, or the reason to show
    /// instead of starting it.
    ///
    /// This is the exact function `voice-session-flow-wiring` should call
    /// before opening a Voice Chat session:
    /// `entitlementSnapshotStore.snapshot.blockReason(for: .voiceChat)`.
    func blockReason(for feature: AIFeature) -> AIFeatureBlockReason? {
        switch self {
        case .trialActive(let remainingCredits):
            return remainingCredits <= 0 ? .trialExhausted : nil

        case .trialExhausted:
            return .trialExhausted

        case .subscriptionExpired:
            return .subscriptionExpired

        case .readerActive(let period), .voiceActive(let period):
            switch feature {
            case .narration:
                return period.remainingNarrationSeconds <= 0 ? .narrationAllowanceExhausted : nil
            case .voiceChat:
                return period.remainingVoiceChatSeconds <= 0 ? .voiceChatAllowanceExhausted : nil
            }
        }
    }
}
```

- [ ] **Step 2: Index the new exports**

Add to `apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`, as a new `MARK` section (place it after `MARK: - Entitlement reconciliation`):

```swift
// MARK: - AI-feature exhaustion gate
//
// AIFeature                   — `Entitlements/AIFeatureGate.swift`. .narration
//                                / .voiceChat — the two gate-able AI entry points.
// AIFeatureBlockReason        — `Entitlements/AIFeatureGate.swift`. Why an AI
//                                feature tap was intercepted. Identifiable.
// EntitlementSnapshot.blockReason(for:)
//                              — `Entitlements/AIFeatureGate.swift`. Pure access
//                                check on plan 12's EntitlementSnapshot (RishiCore).
//                                Call before starting narration or a Voice Chat session.
```

- [ ] **Step 3: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/AIFeatureGate.swift apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift
git commit -m "Add the AI-feature exhaustion gate on EntitlementSnapshot"
```

---

### Task 4: Allowance formatting + warning thresholds

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/AllowanceFormatter.swift`

Pure, deterministic, locale-pinned helpers — same shape as the existing `SyncStatusFormatter` (`RishiSync/Sources/RishiSync/UI/SyncStatusFormatter.swift`): a plain `enum` namespace of `static func`s, `en_US_POSIX` for date formatting so output doesn't depend on the runtime locale.

Two documented warning thresholds (task requirement: "define and document"):
- **Trial credits:** low when remaining `< 5` credits (spec explicitly suggests this exact number).
- **Paid time allowances:** low when remaining `< 10%` of that plan's period allowance for that feature (spec: "warn before a limit"; 10% is this plan's chosen definition of "before").

Per-plan period totals are hardcoded from the pricing table (`2026-07-17-no-card-credit-trial-design.md`: Reader = 2h narration / 10min Voice Chat; Voice = 4h narration / 30min Voice Chat) because `EntitlementSnapshot.PaidPeriod` carries *remaining* seconds, not the period total — the total is a plan-level constant, not per-request server state.

- [ ] **Step 1: Create the formatter + thresholds**

```swift
import Foundation

/// Per-plan monthly allowance totals (pricing table in
/// `2026-07-17-no-card-credit-trial-design.md`). Used only to compute the
/// "less than 10% remaining" warning threshold — `EntitlementSnapshot.PaidPeriod`
/// carries remaining seconds, not the period total.
enum PlanAllowance {
    static let readerNarrationSeconds = 2 * 60 * 60
    static let readerVoiceChatSeconds = 10 * 60
    static let voiceNarrationSeconds = 4 * 60 * 60
    static let voiceVoiceChatSeconds = 30 * 60
}

/// Documented warning thresholds. See Task 4 rationale in
/// `2026-07-17-no-card-onboarding-allowance-ui.md` for why these exact
/// numbers were chosen.
enum AllowanceWarningThreshold {
    /// Trial credits: warn below this absolute count.
    static let lowTrialCreditsFloor = 5

    /// Paid narration/Voice Chat allowances: warn below this fraction of the
    /// plan's period total.
    static let lowRemainingFraction = 0.10

    static func isLowTrialCredits(_ remaining: Int) -> Bool {
        remaining < lowTrialCreditsFloor
    }

    static func isLowRemaining(_ remaining: Int, of total: Int) -> Bool {
        guard total > 0 else { return false }
        return Double(remaining) / Double(total) < lowRemainingFraction
    }
}

/// Pure, deterministic formatting. Mirrors `SyncStatusFormatter`'s shape
/// (`RishiSync/Sources/RishiSync/UI/SyncStatusFormatter.swift`) — a plain
/// namespace of `static func`s pinned to `en_US_POSIX` so output does not
/// depend on the runtime locale.
enum AllowanceFormatter {

    /// "1 credit remaining" / "42 credits remaining". Never called for a
    /// paid-plan user — see `RemainingAllowanceView`.
    static func creditsDescription(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 credit remaining" : "\(clamped) credits remaining"
    }

    /// "1h 24m" / "45m" / "0m". Deliberately coarse (no seconds) — matches
    /// the spec's "human-readable time" requirement for paid users.
    static func timeRemainingDescription(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    /// "Resets Aug 14" — the period-reset date shown to paid users.
    static func resetDateDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return "Resets \(formatter.string(from: date))"
    }
}
```

- [ ] **Step 2: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/AllowanceFormatter.swift
git commit -m "Add allowance formatting and warning-threshold helpers"
```

---

### Task 5: `RemainingAllowanceView`

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/RemainingAllowanceView.swift`
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`

The component from task scope item 2. One `public` view, switching on the `EntitlementSnapshot` enum's cases directly:
- `.trialActive(let remainingCredits)` → credit counter (warning color below the floor).
- `.readerActive(let period)` / `.voiceActive(let period)` → narration time remaining + Voice Chat time remaining (warning color below 10%) + the period reset date via `snapshot.periodEnd`. **The switch never binds `remainingCredits` in these branches** — this is the mechanism enforcing "never expose paid internal credits to paid users."
- `.trialExhausted` / `.subscriptionExpired` → a short status row (no numbers to show — the enum cases carry none).

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import RishiUIKit
import RishiCore

/// Renders the account's remaining AI allowance. Trial users see a credit
/// counter; Reader/Voice users see human-readable narration + Voice Chat time
/// remaining and their period reset date — **never** a raw credit number
/// (spec: "Never expose paid internal credits"). Warning color/icon appears
/// below the documented thresholds in `AllowanceWarningThreshold`.
public struct RemainingAllowanceView: View {
    public let snapshot: EntitlementSnapshot

    public init(snapshot: EntitlementSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            switch snapshot {
            case .trialActive(let remainingCredits):
                AllowanceRow(
                    iconName: "bolt.fill",
                    text: AllowanceFormatter.creditsDescription(remainingCredits),
                    isLow: AllowanceWarningThreshold.isLowTrialCredits(remainingCredits)
                )
            case .readerActive(let period):
                planRows(
                    period: period,
                    narrationTotal: PlanAllowance.readerNarrationSeconds,
                    voiceChatTotal: PlanAllowance.readerVoiceChatSeconds
                )
            case .voiceActive(let period):
                planRows(
                    period: period,
                    narrationTotal: PlanAllowance.voiceNarrationSeconds,
                    voiceChatTotal: PlanAllowance.voiceVoiceChatSeconds
                )
            case .trialExhausted:
                AllowanceRow(
                    iconName: "exclamationmark.circle.fill",
                    text: "Trial credits used up",
                    isLow: true
                )
            case .subscriptionExpired:
                AllowanceRow(
                    iconName: "exclamationmark.circle.fill",
                    text: "Subscription expired",
                    isLow: true
                )
            }

            if let periodEnd = snapshot.periodEnd {
                Text(AllowanceFormatter.resetDateDescription(periodEnd))
                    .font(RishiTypography.caption)
                    .foregroundStyle(RishiColor.textMuted)
            }
        }
    }

    private func planRows(
        period: EntitlementSnapshot.PaidPeriod,
        narrationTotal: Int,
        voiceChatTotal: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: RishiSpacing.xs) {
            AllowanceRow(
                iconName: "waveform",
                text: "\(AllowanceFormatter.timeRemainingDescription(seconds: period.remainingNarrationSeconds)) narration left",
                isLow: AllowanceWarningThreshold.isLowRemaining(period.remainingNarrationSeconds, of: narrationTotal)
            )
            AllowanceRow(
                iconName: "mic.fill",
                text: "\(AllowanceFormatter.timeRemainingDescription(seconds: period.remainingVoiceChatSeconds)) Voice Chat left",
                isLow: AllowanceWarningThreshold.isLowRemaining(period.remainingVoiceChatSeconds, of: voiceChatTotal)
            )
        }
    }
}

/// One allowance line: icon + text, colored `RishiColor.warning` when `isLow`.
/// Extracted to a standalone type because `RemainingAllowanceView` reuses it
/// three times (credits / narration / Voice Chat).
private struct AllowanceRow: View {
    let iconName: String
    let text: String
    let isLow: Bool

    var body: some View {
        HStack(spacing: RishiSpacing.s) {
            Image(systemName: iconName)
                .foregroundStyle(isLow ? RishiColor.warning : RishiColor.accent)
            Text(text)
                .font(RishiTypography.body)
                .foregroundStyle(isLow ? RishiColor.warning : RishiColor.textPrimary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Trial — healthy") {
    Form {
        RemainingAllowanceView(snapshot: .trialActive(remainingCredits: 82))
    }
}

#Preview("Trial — low") {
    Form {
        RemainingAllowanceView(snapshot: .trialActive(remainingCredits: 3))
    }
}

#Preview("Reader — low narration") {
    Form {
        RemainingAllowanceView(snapshot: .readerActive(.init(
            periodEndMs: Int64(Date().addingTimeInterval(86_400 * 12).timeIntervalSince1970 * 1000),
            remainingNarrationSeconds: 300,
            remainingVoiceChatSeconds: 480
        )))
    }
}

#Preview("Trial exhausted") {
    Form {
        RemainingAllowanceView(snapshot: .trialExhausted)
    }
}
```

- [ ] **Step 2: Index the new export**

Add to `RishiBilling+API.swift`, in the `MARK: - AI-feature exhaustion gate` section added in Task 3 (or a dedicated line just below it):

```swift
// RemainingAllowanceView      — `UI/RemainingAllowanceView.swift`. Renders the
//                                account's remaining allowance (credits for
//                                trial, human-readable time for Reader/Voice).
//                                Never shows a raw credit number to a paid user.
```

- [ ] **Step 3: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/RemainingAllowanceView.swift apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift
git commit -m "Add RemainingAllowanceView"
```

---

### Task 6: Wire `RemainingAllowanceView` into Settings (fully live)

**Files:**
- Modify: `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Billing/BillingSection.swift`
- Modify: `apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/SettingsScreen.swift`
- Modify: `apps/apple/rishi/rishi/Settings/SettingsContent.swift`

`BillingSection` already lives in the Settings screen next to `ManageSubscriptionRow` — the natural, existing home for "here's your allowance." Add an optional `entitlementSnapshot` parameter (default `nil`, so every existing call site — including the two `#Preview`s and `SettingsScreenSmokeTests`'s two constructions — keeps compiling unchanged) and render `RemainingAllowanceView` above `ManageSubscriptionRow` when present. Because plan 12 already made `services.entitlementSnapshotStore` live everywhere in the app target, the production call site in `SettingsContent.swift` passes the real value directly — this wiring is complete, not deferred.

- [ ] **Step 1: Modify `BillingSection`**

Current (`apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/Billing/BillingSection.swift:12-30`):

```swift
@available(iOS 18.4, *)
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver

    public init(entitlement: ReaderAppEntitlementFlag.Resolver = .production) {
        self.entitlement = entitlement
    }

    public var body: some View {
        Section {
            ManageSubscriptionRow()
        } header: {
            Text("Subscription")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}
```

Replace with:

```swift
@available(iOS 18.4, *)
public struct BillingSection: View {

    public let entitlement: ReaderAppEntitlementFlag.Resolver

    /// `nil` only in previews/tests that don't construct a full snapshot
    /// store. Production always passes a real value — see
    /// `SettingsContent.swift`'s `SettingsScreen(...)` call site.
    public let entitlementSnapshot: EntitlementSnapshot?

    public init(
        entitlement: ReaderAppEntitlementFlag.Resolver = .production,
        entitlementSnapshot: EntitlementSnapshot? = nil
    ) {
        self.entitlement = entitlement
        self.entitlementSnapshot = entitlementSnapshot
    }

    public var body: some View {
        Section {
            if let entitlementSnapshot {
                RemainingAllowanceView(snapshot: entitlementSnapshot)
            }
            ManageSubscriptionRow()
        } header: {
            Text("Subscription")
                .font(RishiTypography.titleM)
                .foregroundStyle(RishiColor.textPrimary)
        }
    }
}
```

- [ ] **Step 2: Thread it through `SettingsScreen`**

Current (`apps/apple/Packages/RishiSettings/Sources/RishiSettings/UI/SettingsScreen.swift:56-58`):

```swift
    /// Entitlement resolver — defaults to `.production` (reads
    /// `ReaderAppEntitlementFlag.isGranted`); tests override.
    public let billingEntitlement: ReaderAppEntitlementFlag.Resolver
```

Add immediately below it:

```swift

    /// The account's current entitlement snapshot (plan 12), threaded
    /// straight to `BillingSection` for `RemainingAllowanceView`. `nil` only
    /// in previews/tests.
    public let entitlementSnapshot: EntitlementSnapshot?
```

Current init signature (`SettingsScreen.swift:83`):

```swift
        billingEntitlement: ReaderAppEntitlementFlag.Resolver = .production,
```

Add immediately below it:

```swift
        entitlementSnapshot: EntitlementSnapshot? = nil,
```

Current init body (`SettingsScreen.swift:102`):

```swift
        self.billingEntitlement = billingEntitlement
```

Add immediately below it:

```swift
        self.entitlementSnapshot = entitlementSnapshot
```

Current body call site (`SettingsScreen.swift:135`):

```swift
                BillingSection(entitlement: billingEntitlement)
```

Replace with:

```swift
                BillingSection(entitlement: billingEntitlement, entitlementSnapshot: entitlementSnapshot)
```

- [ ] **Step 3: Pass the live snapshot at the production call site**

Current (`apps/apple/rishi/rishi/Settings/SettingsContent.swift:52-54`):

```swift
                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: services.telemetryStore,
                    footerDetectionStore: services.footerDetectionStore,
```

Replace with:

```swift
                    onSyncNow: { Task { await sync.syncNow() } },
                    telemetryStore: services.telemetryStore,
                    footerDetectionStore: services.footerDetectionStore,
                    entitlementSnapshot: services.entitlementSnapshotStore.snapshot,
```

- [ ] **Step 4: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiSettings`
Expected: builds clean (existing `SettingsScreenSmokeTests` still compiles — both `BillingSection(entitlement:)` calls there use the now-defaulted `entitlementSnapshot: nil`).

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/Settings/SettingsContent.swift`
Expected: no error specific to `entitlementSnapshot` or `entitlementSnapshotStore` (cross-file sibling-symbol errors from the isolated typecheck are expected and out of scope, per `apps/apple/CLAUDE.md`'s documented fallback-command limitation).

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Packages/RishiSettings apps/apple/rishi/rishi/Settings/SettingsContent.swift
git commit -m "Show remaining allowance in Settings billing section"
```

---

### Task 7: `AIFeatureUpgradePrompt`

**Files:**
- Create: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/AIFeatureUpgradePrompt.swift`
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift`

The task-3 component: a non-blocking sheet (never a full-screen app-wide block — core reading stays available underneath) shown when an `AIFeatureBlockReason` fires. Copy varies by reason. `onUpgrade` is a caller-supplied closure (the call sites in Tasks 9-10 wire it to the existing `onRequestPaywall` hook), `onDismiss` just closes the sheet and lets the user keep reading.

- [ ] **Step 1: Create the prompt**

```swift
import SwiftUI
import RishiUIKit

extension AIFeatureBlockReason {
    var title: String {
        switch self {
        case .trialExhausted:
            return "You're out of trial credits"
        case .subscriptionExpired:
            return "Your subscription has expired"
        case .narrationAllowanceExhausted:
            return "You've used this month's narration time"
        case .voiceChatAllowanceExhausted:
            return "You've used this month's Voice Chat time"
        }
    }

    var message: String {
        switch self {
        case .trialExhausted:
            return "Upgrade to Rishi Reader or Rishi Voice to keep listening. Your books stay fully readable either way."
        case .subscriptionExpired:
            return "Renew your subscription to keep using Natural AI narration and Voice Chat. Your books stay fully readable either way."
        case .narrationAllowanceExhausted:
            return "Narration resets next period, or upgrade to Rishi Voice for more. Reading stays available."
        case .voiceChatAllowanceExhausted:
            return "Voice Chat resets next period, or upgrade to Rishi Voice for more. Reading stays available."
        }
    }
}

/// Non-blocking upgrade prompt shown at the moment an AI feature is
/// intercepted (TTS play button, Voice Chat start) — never a full-screen,
/// app-wide block. Present as a `.sheet(item:)`; dismissing it always leaves
/// the reader fully usable.
public struct AIFeatureUpgradePrompt: View {
    public let reason: AIFeatureBlockReason
    public let onUpgrade: () -> Void
    public let onDismiss: () -> Void

    public init(
        reason: AIFeatureBlockReason,
        onUpgrade: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.reason = reason
        self.onUpgrade = onUpgrade
        self.onDismiss = onDismiss
    }

    public var body: some View {
        RishiScreenScaffold(actionPlacement: .pinnedToBottom) {
            VStack(spacing: RishiSpacing.l) {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(RishiColor.accent)
                    .accessibilityHidden(true)

                Text(reason.title)
                    .font(RishiTypography.titleM)
                    .foregroundStyle(RishiColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(reason.message)
                    .font(RishiTypography.body)
                    .foregroundStyle(RishiColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RishiSpacing.l)
            }
        } actions: {
            VStack(spacing: RishiSpacing.s) {
                Button(action: onUpgrade) {
                    Text("See plans")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RishiSpacing.m)
                }
                .buttonStyle(.borderedProminent)
                .tint(RishiColor.accent)
                .accessibilityIdentifier("ai-upgrade-prompt-see-plans")

                Button("Not now", action: onDismiss)
                    .accessibilityIdentifier("ai-upgrade-prompt-dismiss")
            }
            .padding(.horizontal, RishiSpacing.l)
            .padding(.bottom, RishiSpacing.l)
        }
    }
}

#Preview("Trial exhausted") {
    AIFeatureUpgradePrompt(reason: .trialExhausted, onUpgrade: {}, onDismiss: {})
}

#Preview("Voice Chat allowance exhausted") {
    AIFeatureUpgradePrompt(reason: .voiceChatAllowanceExhausted, onUpgrade: {}, onDismiss: {})
}
```

- [ ] **Step 2: Index the new export**

Add to `RishiBilling+API.swift`'s `MARK: - AI-feature exhaustion gate` section:

```swift
// AIFeatureUpgradePrompt      — `UI/AIFeatureUpgradePrompt.swift`. Non-blocking
//                                sheet shown when an AI feature is intercepted.
//                                Present via `.sheet(item:)`; core reading is
//                                never blocked.
```

- [ ] **Step 3: Verify**

Run: `swift test --package-path apps/apple/Packages/RishiBilling`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/AIFeatureUpgradePrompt.swift apps/apple/Packages/RishiBilling/Sources/RishiBilling/RishiBilling+API.swift
git commit -m "Add AIFeatureUpgradePrompt"
```

---

### Task 8: Trigger the no-card intro from `RootView`

**Files:**
- Modify: `apps/apple/rishi/rishi/AppDependencies.swift`
- Modify: `apps/apple/rishi/rishi/AppDependencies+Settings.swift`
- Modify: `apps/apple/rishi/rishi/ServiceGraphFactory.swift`
- Modify: `apps/apple/rishi/rishi/RootView.swift`

Wire the Task 1/2 pieces end to end: construct the store, expose it on `AppDependencies`, and present `NoCardTrialScreen` from `RootView` exactly once per signed-in account, after the existing device-scoped onboarding wizard's `fullScreenCover` (`showOnboarding`) has finished — so the two full-screen covers never race each other.

This task's diffs are all in regions of `RootView.swift`/`AppDependencies.swift`/`ServiceGraphFactory.swift` that plan 12 does not touch (plan 12 only touches the `.signedIn` switch body, the `subscriptionService` environment property, and `realBody(deps:)`'s environment-injection line — none overlap with the `.task`/`fullScreenCover` block or the `BootstrappedServices` field list ordering used below). The "current" snippets quoted below are the post-plan-12 file contents.

- [ ] **Step 1: Add the field to `BootstrappedServices`**

Current (`apps/apple/rishi/rishi/AppDependencies.swift:161-162`):

```swift
    let onboardingState: any OnboardingState
    let onboardingCoordinator: OnboardingCoordinator
```

Replace with:

```swift
    let onboardingState: any OnboardingState
    let trialOnboardingState: any TrialOnboardingState
    let onboardingCoordinator: OnboardingCoordinator
```

- [ ] **Step 2: Expose it on `AppDependencies`**

Current (`apps/apple/rishi/rishi/AppDependencies+Settings.swift`, full file):

```swift
import Foundation
import RishiSettings
import RishiOnboarding



extension AppDependencies {
    var telemetryStore: any TelemetryStore { services!.telemetryStore }
    var footerDetectionStore: any FooterDetectionStore { services!.footerDetectionStore }
    var onboardingState: any OnboardingState { services!.onboardingState }
    var onboardingCoordinator: OnboardingCoordinator { services!.onboardingCoordinator }
    var readerDefaults: AppReaderDefaults { services!.readerDefaults }
}
```

Replace the `onboardingState` line with:

```swift
    var onboardingState: any OnboardingState { services!.onboardingState }
    var trialOnboardingState: any TrialOnboardingState { services!.trialOnboardingState }
```

- [ ] **Step 3: Construct it in `ServiceGraphFactory`**

Current (`apps/apple/rishi/rishi/ServiceGraphFactory.swift:358-361`):

```swift
        let onboardingState = UserDefaultsOnboardingState()
        let onboardingCoordinator = await MainActor.run {
            OnboardingCoordinator(state: onboardingState)
        }
```

Replace with:

```swift
        let onboardingState = UserDefaultsOnboardingState()
        let trialOnboardingState = UserDefaultsTrialOnboardingState()
        let onboardingCoordinator = await MainActor.run {
            OnboardingCoordinator(state: onboardingState)
        }
```

Current (`apps/apple/rishi/rishi/ServiceGraphFactory.swift:415`):

```swift
            onboardingState: onboardingState,
```

Replace with:

```swift
            onboardingState: onboardingState,
            trialOnboardingState: trialOnboardingState,
```

- [ ] **Step 4: Present it from `RootView`**

Current (`apps/apple/rishi/rishi/RootView.swift:9-23`):

```swift
struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    @State private var authProbeComplete = false

    @State private var entitlementResolved = false

    @State private var showOnboarding = false
    @Environment(CurrentUserBox.self) private var currentUserBox
```

Replace with:

```swift
struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.rishiAuthService) private var auth
    @Environment(\.appDependencies) private var deps

    @State private var currentUser: User? = nil
    @State private var bootstrapped = false

    @State private var authProbeComplete = false

    @State private var entitlementResolved = false

    @State private var showOnboarding = false
    @State private var showNoCardTrialIntro = false
    @Environment(CurrentUserBox.self) private var currentUserBox
```

Current (`apps/apple/rishi/rishi/RootView.swift:149-163`, the end of `realBodyContent`):

```swift
        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: { showOnboarding = false }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: { showOnboarding = false }
                )
            }
        #endif
    }
}
```

Replace with:

```swift
        #if canImport(UIKit)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                        Task { await presentNoCardTrialIntroIfNeeded(deps: deps) }
                    }
                )
            }
        #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingHost(
                    services: deps.services!,
                    onCompleted: {
                        showOnboarding = false
                        Task { await presentNoCardTrialIntroIfNeeded(deps: deps) }
                    }
                )
            }
        #endif
            .fullScreenCover(isPresented: $showNoCardTrialIntro) {
                NoCardTrialScreen(onGotIt: { showNoCardTrialIntro = false })
            }
    }

    /// Shows the no-card trial explainer exactly once per account. Called
    /// after the device-scoped onboarding wizard's cover has closed (or was
    /// never shown), so the two full-screen covers never race — and again
    /// from the initial bootstrap `.task` for the "wizard already completed
    /// on a prior launch, but this account hasn't seen the intro yet" case
    /// (e.g. a second account signing in on this device).
    private func presentNoCardTrialIntroIfNeeded(deps: AppDependencies) async {
        guard case .signedIn(let user) = currentUserBox.state else { return }
        let alreadySeen = await deps.trialOnboardingState.hasSeenNoCardIntro(userId: user.id)
        guard !alreadySeen else { return }
        await deps.trialOnboardingState.setHasSeenNoCardIntro(true, userId: user.id)
        showNoCardTrialIntro = true
    }
```

Current (`apps/apple/rishi/rishi/RootView.swift:125-147`, inside the same `.task`):

```swift
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true

            let probedUser = await auth?.currentUser
            currentUser = probedUser
            authProbeComplete = true

            if probedUser != nil {
                async let completedAsync = deps.onboardingState
                    .hasCompletedOnboarding()

                let completed = await completedAsync

                entitlementResolved = true
                showOnboarding = !completed
            } else {
                let completed = await deps.onboardingState
                    .hasCompletedOnboarding()
                showOnboarding = !completed
            }

        }
```

Replace with:

```swift
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true

            let probedUser = await auth?.currentUser
            currentUser = probedUser
            authProbeComplete = true

            if probedUser != nil {
                async let completedAsync = deps.onboardingState
                    .hasCompletedOnboarding()

                let completed = await completedAsync

                entitlementResolved = true
                showOnboarding = !completed
                if completed {
                    await presentNoCardTrialIntroIfNeeded(deps: deps)
                }
            } else {
                let completed = await deps.onboardingState
                    .hasCompletedOnboarding()
                showOnboarding = !completed
            }

        }
```

- [ ] **Step 5: Verify**

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/RootView.swift`
Also spot-check the two other edited files parse: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/AppDependencies+Settings.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift`
(These app-target files depend on many sibling types the standalone typecheck won't resolve — treat resolvable syntax/type errors as real, and defer full confirmation to the end-of-phase `xcodebuild` the orchestrator runs per `apps/apple/CLAUDE.md`.)

- [ ] **Step 6: Commit**

```bash
git add apps/apple/rishi/rishi/AppDependencies.swift apps/apple/rishi/rishi/AppDependencies+Settings.swift apps/apple/rishi/rishi/ServiceGraphFactory.swift apps/apple/rishi/rishi/RootView.swift
git commit -m "Trigger no-card trial intro once per account after onboarding"
```

---

### Task 9: Intercept the TTS play button

**Files:**
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`

`onReadAloud` (the closure driving the `reader.toolbar.readAloud` button in both `ReaderScreen` and the PDF `ToolBar` — both route through this single app-target closure) currently starts narration unconditionally. Gate it: if `blockReason(for: .narration)` fires on `services.entitlementSnapshotStore.snapshot`, show `AIFeatureUpgradePrompt` instead of starting playback, and never touch `readAloud`/`ReadAloudController` in that case. `services.entitlementSnapshotStore` is already live (plan 12) — no closures, no defaults, no deferred wiring.

- [ ] **Step 1: Add the gating state**

Current (`apps/apple/rishi/rishi/Reader/ReaderDestination.swift:32-34`):

```swift
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
```

Replace with:

```swift
    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    @State private var pendingNarrationUpgradePrompt: AIFeatureBlockReason?
```

- [ ] **Step 2: Gate `onReadAloud`**

Current (`apps/apple/rishi/rishi/Reader/ReaderDestination.swift:68-85`):

```swift
            onReadAloud: {
                
                Task {
  
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            ttsPresence: services.ttsPresenceController,
                            coordidator: services.audioCoordinator,
                            userId: userId
                        )
                    }
                    await readAloud?.startReader(vm: vm)
                }
            } ,
```

Replace with:

```swift
            onReadAloud: {
                if let reason = services.entitlementSnapshotStore.snapshot.blockReason(for: .narration) {
                    pendingNarrationUpgradePrompt = reason
                    return
                }

                Task {
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            ttsPresence: services.ttsPresenceController,
                            coordidator: services.audioCoordinator,
                            userId: userId
                        )
                    }
                    await readAloud?.startReader(vm: vm)
                }
            } ,
```

- [ ] **Step 3: Present both upgrade-prompt sheets**

Current (`apps/apple/rishi/rishi/Reader/ReaderDestination.swift:153-170`, the trailing `.sheet` block — this is the last modifier chain on the view):

```swift
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: services.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        Task { await ra.applySettings(settings) }
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
```

Add immediately below it (still inside the same `body`, before the view's closing brace):

```swift
        .sheet(item: $pendingNarrationUpgradePrompt) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    pendingNarrationUpgradePrompt = nil
                    onRequestPaywall("narration_exhausted")
                },
                onDismiss: { pendingNarrationUpgradePrompt = nil }
            )
        }
        .sheet(item: Binding(
            get: { voiceEntry.pendingUpgradePrompt },
            set: { newValue in if newValue == nil { voiceEntry.dismissUpgradePrompt() } }
        )) { reason in
            AIFeatureUpgradePrompt(
                reason: reason,
                onUpgrade: {
                    voiceEntry.dismissUpgradePrompt()
                    onRequestPaywall("voice_chat_exhausted")
                },
                onDismiss: { voiceEntry.dismissUpgradePrompt() }
            )
        }
```

(The `voiceEntry.pendingUpgradePrompt` / `dismissUpgradePrompt()` members are added in Task 10 — this step and Task 10 are best done in the same commit since neither compiles alone.)

- [ ] **Step 4: Verify**

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/Reader/ReaderDestination.swift`
Full compile confirmation happens after Task 10 (same file, same commit) via the orchestrator's end-of-phase `xcodebuild`.

- [ ] **Step 5: Commit together with Task 10** (see Task 10, Step 3).

---

### Task 10: Intercept the Voice Chat start button

**Files:**
- Modify: `apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift`
- Modify: `apps/apple/rishi/rishi/Reader/ReaderDestination.swift`

`ReaderVoiceEntry.presentVoice` is the single implementation behind every Voice Chat entry point in the app — the EPUB toolbar (`ReaderScreen.swift:603`), the PDF toolbar (`ToolBar.swift:56`), and the "open Voice Chat" button inside the Read-Aloud overlay (`ReaderDestination.swift`'s `onOpenVoiceChat`) all call through the `ReaderVoicePresenter` protocol, whose only production implementation is this class. Gating here — one place — covers all three call sites.

Because `presentVoice` is a synchronous, non-throwing protocol method invoked directly from a SwiftUI button action, the class needs to become `@Observable` so `ReaderDestination` can react to "a prompt should now be shown" by observing a property, rather than `presentVoice` needing to return a value or take a completion handler (which would break the `ReaderVoicePresenter` protocol signature used by `RishiReader`).

`ReaderVoiceEntry` takes the live `EntitlementSnapshotStore` (plan 12) as a constructor parameter, defaulted to `nil` **only** so the existing `ReaderVoiceEntryLanguageTests.swift` (which constructs a 3-arg `ReaderVoiceEntry` with no knowledge of entitlement gating) keeps compiling unchanged — production always passes the real, live store from `services`.

- [ ] **Step 1: Add the store, `@Observable` state, and the gate**

Current (`apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift`, full file):

```swift
import Foundation
import RishiCore
import RishiBilling
import RishiCore
import RishiReader
import RishiSettings

@MainActor
final class ReaderVoiceEntry: ReaderVoicePresenter {

    private let voicePresenter: VoiceSessionPresenter
    private let voiceLanguageProvider: @MainActor () -> VoiceLanguageOption
    //private let entitlementProvider: () async -> EntitlementLevel
    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        voiceLanguageProvider: @escaping @MainActor () -> VoiceLanguageOption,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
        self.voiceLanguageProvider = voiceLanguageProvider
        self.onRequestPaywall = onRequestPaywall
    }

    func presentVoice(
        bookId: BookID,
        context: ReaderVoiceContext,
        initialQuote: String?
    ) {

        let snapshot = BookContextSnapshot(
            bookId: bookId,
            currentPage: context.currentPage,
            pageText: context.pageText,
            outline: BookOutlineDTO(
                title: context.title,
                author: context.author,
                chapters: context.chapters
            ),
            activeParagraphText: context.activeParagraphText
        )

        Task {
            await voicePresenter.start(
                bookId: bookId,
                language: voiceLanguageProvider().rawValue,
                initialQuote: initialQuote,
                bookContext: snapshot
            )
        }
    }
}
```

Replace with:

```swift
import Foundation
import Observation
import RishiCore
import RishiBilling
import RishiCore
import RishiReader
import RishiSettings

/// `@Observable` so `ReaderDestination` can present `pendingUpgradePrompt` as
/// a `.sheet(item:)` — `presentVoice` itself must stay synchronous and
/// non-throwing to satisfy `ReaderVoicePresenter`, so it cannot return the
/// block reason directly; it publishes it instead.
@MainActor
@Observable
final class ReaderVoiceEntry: ReaderVoicePresenter {

    /// Set by `presentVoice` when the tap is intercepted. `ReaderDestination`
    /// observes this to drive its upgrade-prompt sheet; `dismissUpgradePrompt()`
    /// clears it.
    public private(set) var pendingUpgradePrompt: AIFeatureBlockReason?

    private let voicePresenter: VoiceSessionPresenter
    private let voiceLanguageProvider: @MainActor () -> VoiceLanguageOption

    /// The live entitlement snapshot store (plan 12). `nil` only to keep
    /// `ReaderVoiceEntryLanguageTests.swift`'s 3-arg construction compiling —
    /// production always passes `services.entitlementSnapshotStore`.
    private let entitlementSnapshotStore: EntitlementSnapshotStore?

    private let onRequestPaywall: (String) -> Void

    init(
        voicePresenter: VoiceSessionPresenter,
        voiceLanguageProvider: @escaping @MainActor () -> VoiceLanguageOption,
        entitlementSnapshotStore: EntitlementSnapshotStore? = nil,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self.voicePresenter = voicePresenter
        self.voiceLanguageProvider = voiceLanguageProvider
        self.entitlementSnapshotStore = entitlementSnapshotStore
        self.onRequestPaywall = onRequestPaywall
    }

    func presentVoice(
        bookId: BookID,
        context: ReaderVoiceContext,
        initialQuote: String?
    ) {
        if let reason = entitlementSnapshotStore?.snapshot.blockReason(for: .voiceChat) {
            pendingUpgradePrompt = reason
            return
        }

        let contextSnapshot = BookContextSnapshot(
            bookId: bookId,
            currentPage: context.currentPage,
            pageText: context.pageText,
            outline: BookOutlineDTO(
                title: context.title,
                author: context.author,
                chapters: context.chapters
            ),
            activeParagraphText: context.activeParagraphText
        )

        Task {
            await voicePresenter.start(
                bookId: bookId,
                language: voiceLanguageProvider().rawValue,
                initialQuote: initialQuote,
                bookContext: contextSnapshot
            )
        }
    }

    /// Dismisses the upgrade prompt without starting a session. Reading
    /// continues uninterrupted — this never blocks anything but the AI
    /// feature itself.
    func dismissUpgradePrompt() {
        pendingUpgradePrompt = nil
    }
}
```

(The local `BookContextSnapshot` variable is renamed from `snapshot` to `contextSnapshot` in this diff — it previously shadowed nothing, but now sits in the same scope as the entitlement snapshot check above it, so keeping two different names avoids any ambiguity for a future reader of this method.)

- [ ] **Step 2: Pass the live store from `ReaderDestination`**

Current (`apps/apple/rishi/rishi/Reader/ReaderDestination.swift:49-55`, inside `init`):

```swift
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            voiceLanguageProvider: { services.readerDefaults.voiceLanguage },
            onRequestPaywall: onRequestPaywall
        ))
    }
```

Replace with:

```swift
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            voiceLanguageProvider: { services.readerDefaults.voiceLanguage },
            entitlementSnapshotStore: services.entitlementSnapshotStore,
            onRequestPaywall: onRequestPaywall
        ))
    }
```

- [ ] **Step 3: `ReaderVoiceEntryLanguageTests` compiles unchanged**

`apps/apple/rishi/rishiTests/Voice/ReaderVoiceEntryLanguageTests.swift:107-111` constructs `ReaderVoiceEntry(voicePresenter:voiceLanguageProvider:onRequestPaywall:)` without `entitlementSnapshotStore` — this keeps compiling because of the `= nil` default added in Step 1, and `presentVoice`'s `entitlementSnapshotStore?.snapshot...` short-circuits to "never block" when `nil`. No test file changes needed. (Per this plan's testing override, do not add new tests here — this is just confirming the existing one still builds.)

- [ ] **Step 4: Verify + commit together with Task 9**

Run: `xcrun --sdk iphonesimulator swiftc -typecheck apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift apps/apple/rishi/rishi/Reader/ReaderDestination.swift`

```bash
git add apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift apps/apple/rishi/rishi/Reader/ReaderDestination.swift
git commit -m "Intercept TTS play and Voice Chat start with the exhaustion upgrade prompt"
```

---

## Self-review

**Spec coverage:**
- No-card onboarding (100 credits, no card, concise usage explanation), shown once, per-account: Tasks 1, 2, 8.
- Remaining-allowance UI: trial → credits; Reader/Voice → human-readable narration + Voice Chat time, never raw credits; warning treatment below a documented threshold; reset date for paid users: Tasks 3-6.
- Exhaustion upgrade screen at the TTS play button and Voice Chat start button, non-blocking for core reading: Tasks 7, 9, 10.
- `trial_exhausted` / `subscription_expired` / mid-period narration-exhausted / mid-period Voice-Chat-exhausted are all distinct `AIFeatureBlockReason` cases with distinct copy, and correspond 1:1 to plan 12's `EntitlementClientState` cases: Task 3, 7.
- Package boundaries respected — reused `RishiOnboarding` (device-scoped wizard's sibling package) and `RishiBilling`'s existing `UI/` view layer; no new package, no `Package.swift` edits: File plan header.
- Every consumer reads plan 12's real, live `EntitlementSnapshot`/`EntitlementSnapshotStore` — no invented type, no deferred/placeholder wiring: "Upstream dependency — resolved" section, Tasks 3, 6, 9, 10.

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N" anywhere above; every step has complete code. The only intentionally-optional parameter left in the final design (`ReaderVoiceEntry`'s `entitlementSnapshotStore: EntitlementSnapshotStore? = nil`) exists solely to keep one pre-existing test file compiling, and is documented as such at that task — production always supplies the real value.

**Type consistency:** `AIFeature`, `AIFeatureBlockReason`, `blockReason(for:)` (Task 3) are used with identical names/signatures in Tasks 4-10, against plan 12's real `EntitlementSnapshot`/`EntitlementSnapshotStore`/`EntitlementSnapshot.PaidPeriod`. `TrialOnboardingState` / `UserDefaultsTrialOnboardingState` (Task 1) match their use in Task 8. `RemainingAllowanceView` (Task 5) and `AIFeatureUpgradePrompt` (Task 7) match their call sites in Tasks 6, 9, 10.

---

## Exports for downstream plans

**Onboarding-flag persistence:**
- Type: `TrialOnboardingState` protocol / `UserDefaultsTrialOnboardingState` (production) — `RishiOnboarding/Sources/RishiOnboarding/Storage/TrialOnboardingState.swift`.
- Key scheme: `"onboarding.noCardTrial.seen.<UserID.uuidString>"` — per-account, not per-device.
- Access pattern: `await deps.trialOnboardingState.hasSeenNoCardIntro(userId: user.id)` / `await deps.trialOnboardingState.setHasSeenNoCardIntro(true, userId: user.id)`, wired into `BootstrappedServices` in `AppDependencies.swift` and exposed via `AppDependencies+Settings.swift`.

**Remaining-allowance view components:**
- `RemainingAllowanceView(snapshot: EntitlementSnapshot)` — `RishiBilling/Sources/RishiBilling/UI/RemainingAllowanceView.swift`. Public SwiftUI view; switches on the `EntitlementSnapshot` enum's cases to show credits (`.trialActive`) or human-readable time + reset date (`.readerActive`/`.voiceActive`), never raw credits for a paid state.
- `AllowanceFormatter` / `AllowanceWarningThreshold` / `PlanAllowance` — `RishiBilling/Sources/RishiBilling/UI/AllowanceFormatter.swift`. Internal to `RishiBilling`; not part of the public surface, but documents the exact warning thresholds (`<5` trial credits, `<10%` of period allowance) if another plan needs to match this UI's behavior in copy or tests.

**Exhaustion-prompt component's public API** (for `voice-session-flow-wiring` to call before starting a session):
- `EntitlementSnapshot.blockReason(for feature: AIFeature) -> AIFeatureBlockReason?` — `RishiBilling/Sources/RishiBilling/Entitlements/AIFeatureGate.swift`. Pure, synchronous, side-effect-free. Call `entitlementSnapshotStore.snapshot.blockReason(for: .voiceChat)` immediately before opening a Voice Chat session; a non-`nil` result means the session should not start.
- `AIFeatureUpgradePrompt(reason: AIFeatureBlockReason, onUpgrade: () -> Void, onDismiss: () -> Void)` — `RishiBilling/Sources/RishiBilling/UI/AIFeatureUpgradePrompt.swift`. Public SwiftUI view; present as `.sheet(item:)` keyed on an `AIFeatureBlockReason?` (it is `Identifiable`). `onUpgrade` should invoke the same `onRequestPaywall` hook this plan reuses (`ReaderDestination` → `ReaderDestinationView` → `LibraryTabView.model.requestPaywall`), or an equivalent surface if calling from outside the reader.
- Reference implementation of the interception pattern: `ReaderVoiceEntry.presentVoice` (`apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift`) — check `blockReason(for:)` first, publish `pendingUpgradePrompt` and `return` early if non-`nil`, otherwise proceed with the session as before. `ReaderVoiceEntry` already holds a live `EntitlementSnapshotStore` reference, obtainable the same way from any other call site via `services.entitlementSnapshotStore` / `deps.entitlementSnapshotStore`.

# Premium-only hard paywall (with 7-day trial) — Design

- Date: 2026-06-19
- Status: Approved (pending spec review)
- Area: apps/apple (RishiBilling, app routing) — no worker changes

## Context & decision

Basic EPUB/PDF reading is commoditized (Apple Books, Kindle do it for free). Rishi's
differentiation is its AI layer: Read Aloud (TTS), Voice Chat, and cross-device Sync.
Rather than ship a free reading tier and upsell the AI features, we sell from the start:
the app becomes **premium-only behind a hard paywall, fronted by the existing 7-day free
trial**.

This supersedes the earlier "freemium upsell pass" (library banner, Pro badges,
per-feature paywall triggers, Settings upgrade CTA) — those surfaces exist to convert
free users *inside* the app, and there are no free users inside a hard-paywalled app.

Decision (confirmed): **hard paywall + 7-day free trial**, not pay-immediately. The trial
keeps top-of-funnel viable and gives App Review a way into the app.

## Model

After authentication, gate entry on entitlement:

- signed-out → existing Sign in with Apple flow (unchanged)
- signed-in AND `entitlement == .pro` → the app (unchanged)
- signed-in AND `entitlement == .free` → full-screen, non-dismissible **Paywall Gate**

Key fact that keeps this simple: **an active 7-day trial already resolves to `.pro`** in
both StoreKit `Transaction.currentEntitlements` and the worker's `premium_until`. So
"in trial" == "in the app, free". No new entitlement concept is introduced.

## Architecture

### Routing gate
`RootView` already has a launch sequence that resolves auth and refreshes entitlement.
Insert the gate between "signed in" and the app:

- Source of truth for the decision: `EntitlementReconciler.level` (the unified
  on-device ∪ server signal, most-permissive-wins). It is `@MainActor @Observable`, so
  `RootView` re-renders when it changes.
- `.pro` → render the app (`SignedInView`). `.free` → render `PaywallGate`.

### Reactivity (gate → app with no flash)
- On launch, `EntitlementService` hydrates the last-known level from its UserDefaults
  cache immediately, so returning subscribers do NOT flash the gate. `refresh()` then
  confirms against the server.
- Our sign-out `clearCache()` + `reconciler.reset()` (already shipped) guarantee a fresh
  account cannot inherit the previous user's `.pro`.
- On a successful purchase/trial start, `PurchaseService` calls
  `reconciler.setOnDevice(.pro)`; the observed `level` flips and `RootView` replaces the
  gate with the app automatically — no manual navigation.

### The Paywall Gate screen
Reuse the existing native SwiftUI `PaywallView` / `PaywallViewModel` as the gate body —
it already provides: Monthly/Annual tiers, "7-day free trial" framing, Subscribe, Restore
Purchases, the Guideline 3.1.2 auto-renewal disclosure, Manage Subscriptions, and
Privacy/Terms links. Adaptations:

1. Present it as a **root, full-screen, non-dismissible** view (not the current
   feature-triggered `.sheet`). No swipe-to-dismiss, no close button.
2. Lead with a concise value-prop (Read Aloud · Voice Chat · cross-device Sync).
3. Add a quiet **"Sign out"** secondary action so users are never trapped and App Review
   can exit. Sign-out routes through the existing `\.signOut` chokepoint (clears
   entitlement, returns to sign-in).

Native components only — a full-screen SwiftUI view plus native buttons; no custom modal.

### Go-live switch
`StoreKitIAPFlag.isEnabled` flips **ON for release**. It stops being a dark-rollout flag
and becomes the launch switch. It MUST be ON or the gate would render the "subscriptions
temporarily unavailable" fallback and trap users. The Sign-out escape is the safety net
regardless of flag state.

## What we drop (vs the earlier upsell pass)
- Library upsell banner, Pro badges/locks on controls, per-feature paywall triggers,
  Settings "Upgrade to Pro" CTA. No free users inside the app to see them.
- The existing per-feature entitlement guards (Read Aloud / Voice Chat `guard entitled`)
  may remain as harmless defense-in-depth; they never fire when everyone is `.pro`.

## Out of scope (noted, not built here)
- Reader-toolbar overflow (8 trailing items burying actions in "···") — now a pure
  usability fix, separate small follow-up; not a monetization concern anymore.
- Pricing, trial length, value-prop copy — product decisions (current 7-day trial and
  prices stand unless changed). See docs/PRICING-RISHI-PRO.md.
- App Store Connect product setup + App Review notes (the trial is how review gets in).

## Edge cases
- Trial expires → server `premium_until` passes and on-device entitlement lapses →
  `level` becomes `.free` → gate reappears (must resubscribe). Correct.
- Offline returning subscriber → cached `.pro` shows the app; refresh reconciles later.
- Account switch (A Pro signs out, B signs in) → sign-out cleared cache; B resolves to
  `.free` → gate. Correct.
- Restore Purchases on the gate → `RestoreService` reconciles `.pro` → app.
- Purchase verified server-side before the transaction is finished (existing
  finish-after-verify ordering) — unchanged.

## Testing (Swift Testing)
- Router/gate decision: `.pro` → app; `.free` → gate; trial(`.pro`) → app.
- Reactivity: driving `reconciler` to `.pro` flips gate → app; sign-out from gate clears
  entitlement and returns to sign-in.
- Non-dismissibility: the gate exposes no dismiss affordance other than Sign out /
  successful entitlement.
- Keep existing PaywallViewModel purchase/restore tests green.
- Integrated app build gate (xcodebuild iPhone 17) is the final check.

## Risks
- Funnel: a hard wall sharply reduces who experiences the product; pricing, trial length,
  and the pre-paywall value-prop carry all the weight. No free-reader fallback for churned
  users.
- App Review: hard paywalls are permitted, but reviewers must be able to enter — the
  trial covers this; ensure review notes include a working path (sandbox tester / SIWA).

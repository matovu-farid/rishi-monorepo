# Metered Free-Taste Paywall — Design Spec

**Date:** 2026-06-19
**Status:** Approved (design); pending implementation plan
**Supersedes:** the launch-time hard paywall behavior introduced in
`2026-06-19-premium-only-hard-paywall-design.md` (the gate infrastructure is
reused; only its trigger condition changes).

## Goal

Let a new signed-in user experience the app's paid value (the AI layer —
Read Aloud + Voice Chat) for a bounded free "taste," then lock the whole app
behind the existing paywall once that taste is spent. Reading is free while the
taste lasts; the AI features are the product being sold.

## Product Model (locked)

- **No paywall at launch.** A signed-in `.free` user enters the app, reads
  freely, and can use Read Aloud + Voice Chat immediately.
- **One pooled lifetime budget: 900 seconds (15 minutes)** of AI audio, shared
  across both AI features. Lifetime, non-recurring, no reset.
- Each AI use **debits the pool**. When the pool reaches zero **and** the user
  is not Pro/trial, the **whole-app paywall** appears (reading included).
- **Pro/trial users:** unlimited AI, never walled, pool ignored.
- **Accepted loophole:** a user who never uses an AI feature never depletes the
  pool and is never walled. This is intentional — such users incur no AI cost,
  and the bet is that most users try the AI and convert.

## Architecture

Approach A — **server-authoritative, debit-on-serve**. The Cloudflare worker is
the single source of truth for the budget. The iOS app reads the remaining
budget through the entitlement refresh it already performs, caches it, and uses
it for fast local gating. The worker enforces the hard cap so the budget cannot
be reset by reinstalling or spoofed by the client.

Rejected alternatives:
- **Local-only counter (UserDefaults):** trivially reset by reinstall/sign-out
  and fully spoofable — unacceptable for a paid product.
- **Hybrid (server + dedicated local mirror with live countdown):** smoother
  countdown UI, but the existing entitlement cache already gives instant
  gating; the extra mirror and its reconciliation are not worth it (YAGNI).

## Components

### 1. Gate logic — `AppGate.resolve`

`RishiBilling/Entitlements/AppGate.swift`. Gains one parameter,
`freeAiSecondsRemaining: Int`. New body:

```swift
guard authProbeComplete else { return .loading }
guard isSignedIn else { return .signedOut }
if level == .pro { return .app }                   // Pro/trial: unlimited
guard entitlementResolved else { return .loading } // no flash before /me answers
return freeAiSecondsRemaining > 0 ? .app : .paywall
```

All existing flash-prevention behavior is preserved: the `entitlementResolved`
gate still holds `.free` users in `.loading` until the first server answer, and
Pro/trial still short-circuits to `.app` even before resolution.

### 2. Worker — source of truth

- **Storage:** drizzle migration adds one column to the `user` table:
  `free_ai_seconds_consumed INTEGER NOT NULL DEFAULT 0`. No reset column
  (lifetime pool). The 900-second cap is a server constant, not stored per row.
- **TTS debit (`POST /api/audio/speech`):** replace the `requireActiveSubscription`
  gate with "allowed if Pro **or** `consumed < cap`". On a successful synth,
  debit by **estimated duration** = `ceil(text.length / CHARS_PER_SECOND)` using a
  single tuned constant. If already exhausted and not Pro → `402`.
- **Voice debit:** the ephemeral-key request refuses with `402` when exhausted
  and not Pro. The existing `POST /api/billing/realtime-usage` report converts
  reported audio tokens → seconds and decrements the counter (same client-
  reported path that already feeds Stripe metering; we additionally debit the
  free pool). Debit clamps so `consumed` never exceeds the cap meaningfully.
- **`/api/billing/me` payload:** add `freeAiSecondsRemaining: number` =
  `max(0, cap - consumed)`. This is the single value the app consumes.

### 3. App — `EntitlementService` + DTO

- The response struct decoded from the entitlement endpoint gains
  `freeAiSecondsRemaining: Int?`. The service stores it in its snapshot and
  UserDefaults cache alongside `hasPro`, so a cold launch has a last-known value
  instantly (same caching pattern as `hasPro`).
- Absent field semantics: treated as `0` **only after** a successful resolve.
  Before resolve, `entitlementResolved` keeps the gate in `.loading`.

### 4. App — gate wiring

- **`RootView`:** pass the cached `freeAiSecondsRemaining` into
  `AppGate.resolve(...)`. Read through Observation so the gate re-renders to
  `.paywall` the moment the pool flips to zero (e.g. just after a session usage
  report), without a relaunch.
- **AI button gate sites:** `EPUBReaderDestination`, `PDFReaderDestination`
  (`onReadAloud`) and `ReaderVoiceEntry` (`presentVoice`) currently check
  `level == .pro` then call `onRequestPaywall`. Change each to
  `pro || remaining > 0`. This prevents starting a new AI action when the pool
  is already empty (clean in-reader UX); the whole-app gate is the backstop.
- **Server `402` handling:** if a debit race lets an AI request through and the
  worker returns `402`, the app stops the feature and calls `onRequestPaywall`.
  Defense-in-depth: worker is the hard authority, app gate is the fast path.
- **Paywall messaging:** the whole-app `PaywallGateView` and the in-reader
  paywall accept a copy variant — "you've used your free AI minutes" vs. the
  generic upsell — same view, headline string driven by the trigger reason.

## Edge Cases

- **Reinstall / new device:** budget is server-side per `userId`; survives
  reinstall, cannot be reset client-side.
- **Offline:** AI features already require the network. If `/me` is unreachable
  on launch, `entitlementResolved` stays false → `.loading`, then falls back to
  the cached value (cached `remaining > 0` admits; cached `0` walls). No free-AI
  leak offline because the AI calls themselves require the worker.
- **Pro short-circuit:** Pro/trial never reads the counter.

## Testing (TDD)

Swift Testing for the app, vitest + miniflare D1 for the worker.

- **`AppGateTests`:** free + remaining>0 → `.app`; free + remaining==0 +
  resolved → `.paywall`; free + remaining==0 + not resolved → `.loading`; Pro
  ignores remaining (both resolved states).
- **Worker:** debit math (chars→seconds, tokens→seconds); `402` when exhausted
  and not Pro; Pro bypass; `/me` returns `max(0, cap - consumed)`; debit clamps
  at the cap.
- **`EntitlementService`:** decodes `freeAiSecondsRemaining`; caches it; returns
  it in the snapshot; absent field treated as resolved-zero only.
- **AI gate sites:** budget-exhausted tap routes to the paywall instead of
  starting the feature (existing entitlement-stub pattern).

## Out of Scope

- Time-based backstop for read-only users (loophole accepted).
- Recurring/refreshing budgets.
- Per-feature separate caps.
- Apple usage-metered billing (not supported by StoreKit; the Stripe meter is
  the web rail only).

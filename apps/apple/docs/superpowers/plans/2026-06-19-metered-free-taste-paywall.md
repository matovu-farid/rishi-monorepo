# Metered Free-Taste Paywall Implementation Plan

> **STATUS: PARKED (2026-06-19).** Not scheduled for execution. The team chose
> the lower-effort trial-forward hard-paywall copy instead (see commit history
> for the `subscribeCTATitle` change). Keep this plan for the future: if launch
> data shows too many users bounce at the launch wall, execute this to replace
> the launch-time wall with a 15-minute free AI taste. The design it implements
> is `docs/superpowers/specs/2026-06-19-metered-free-taste-paywall-design.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking. Before ANY task, re-read the spec and
> confirm the app builds (apps/apple/CLAUDE.md build-first rule). Subagents must
> NOT run `xcodebuild rishi`; use `swift test --package-path <pkg>` or
> `xcrun --sdk iphonesimulator swiftc -typecheck <file>`. The MAIN orchestrator
> runs the full `xcodebuild` (iPhone 17, isolated derivedDataPath) as the gate.

**Goal:** Let signed-in free users read freely and use a shared 15-minute pool
of AI audio (Read Aloud + Voice Chat); once the pool is spent, the existing
whole-app paywall returns. Server-authoritative so it cannot be reset or spoofed.

**Architecture:** The Cloudflare worker owns the budget (one integer column on
the `user` table) and debits it where it already sits in the request path (TTS
synth, realtime usage report); it exposes the remainder in the entitlement
payload the iOS app already fetches. The app caches the remainder, feeds it into
the pure `AppGate.resolve`, and gates the AI feature buttons on it. Pro/trial
users short-circuit and ignore the pool.

**Tech Stack:** Cloudflare Workers (Hono), Drizzle ORM + D1, vitest + miniflare;
Swift 6 / SwiftUI / Observation, Swift Testing; StoreKit 2 (unchanged here).

---

## Pre-flight (do once, before Task 1)

The spec assumes the iOS `EntitlementService` reads its entitlement from
`/api/billing/me` (`BillingMeResponse { premium, premiumUntil }`). Earlier
exploration found the app's `EntitlementService.refresh()` may instead decode a
`hasPro` field from a `GetSessionEndpoint` (`/api/auth/get-session`). The new
`freeAiSecondsRemaining` field MUST be added to **whichever endpoint the app
actually consumes**, and returned by the worker there.

- [ ] **Step P1: Confirm the consumed endpoint.**
  Read `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift`
  and the endpoint it calls (`GetSessionEndpoint` definition under
  `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/`). Note the exact
  URL path and the JSON field it decodes for Pro status.
- [ ] **Step P2: Map that path to a worker route.**
  In `workers/worker/src/index.ts`, find the route registration matching the
  path from P1 and the handler file it dispatches to (e.g.
  `workers/worker/src/billing/apple-me.ts`). Record the response-builder
  function. Tasks 5 and 6 below say "the entitlement endpoint / response" —
  substitute the concrete route + handler + Swift endpoint you found here.

---

## Task 1: D1 column for the consumed counter

**Files:**
- Modify: `packages/shared/src/schema.ts` (the `user` table definition, ~lines 214-224)
- Create: a Drizzle migration under the worker's migrations dir (run the
  project's generate command; do not hand-write the SQL filename)

- [ ] **Step 1: Add the column to the schema.**
  In the `user` table definition, add:
  ```ts
  freeAiSecondsConsumed: integer("free_ai_seconds_consumed").notNull().default(0),
  ```
  Match the existing column style in that table (the file already imports
  `integer` from `drizzle-orm/sqlite-core`; if not, add it to the import).

- [ ] **Step 2: Generate the migration.**
  From `workers/worker`, run the repo's drizzle generate script (check
  `workers/worker/package.json` scripts for the exact name, commonly
  `pnpm db:generate` or `pnpm drizzle-kit generate`).
  Expected: a new migration file containing
  `ALTER TABLE user ADD ... free_ai_seconds_consumed ... DEFAULT 0`.

- [ ] **Step 3: Apply to the local miniflare/D1 test DB** per the repo's test
  setup (the existing billing tests already run migrations against miniflare D1;
  match how `workers/worker/src/billing/backfill.test.ts` bootstraps its DB).

- [ ] **Step 4: Commit.**
  ```bash
  git add packages/shared/src/schema.ts workers/worker/drizzle
  git commit -m "feat(worker): add free_ai_seconds_consumed column to user"
  ```

---

## Task 2: Free-budget helper module (worker)

A single module owning the cap constant and the read/debit math, so the TTS
route, the realtime route, and the entitlement route all share one
implementation (DRY).

**Files:**
- Create: `workers/worker/src/billing/free-budget.ts`
- Test: `workers/worker/src/billing/free-budget.test.ts`

- [ ] **Step 1: Write failing tests.**
  ```ts
  import { describe, it, expect } from "vitest";
  import {
    FREE_AI_SECONDS_CAP,
    secondsRemaining,
    charsToSeconds,
    realtimeTokensToSeconds,
  } from "./free-budget";

  describe("free-budget math", () => {
    it("cap is 900 seconds (15 min)", () => {
      expect(FREE_AI_SECONDS_CAP).toBe(900);
    });
    it("remaining clamps at zero and at the cap", () => {
      expect(secondsRemaining(0)).toBe(900);
      expect(secondsRemaining(900)).toBe(0);
      expect(secondsRemaining(1000)).toBe(0);
    });
    it("charsToSeconds rounds up at ~15 chars/sec", () => {
      expect(charsToSeconds(0)).toBe(0);
      expect(charsToSeconds(15)).toBe(1);
      expect(charsToSeconds(16)).toBe(2);
    });
    it("realtimeTokensToSeconds sums audio tokens at the model rate", () => {
      // 1 audio second ~= 50 tokens (gpt-realtime). Tune constant in impl.
      expect(realtimeTokensToSeconds(0, 0)).toBe(0);
      expect(realtimeTokensToSeconds(50, 0)).toBe(1);
      expect(realtimeTokensToSeconds(25, 25)).toBe(1);
    });
  });
  ```

- [ ] **Step 2: Run tests, verify they fail.**
  Run: `pnpm --filter worker test free-budget` (or the repo's vitest invocation).
  Expected: FAIL — module not found.

- [ ] **Step 3: Implement.**
  ```ts
  /** Lifetime free AI audio pool, in seconds (15 minutes). */
  export const FREE_AI_SECONDS_CAP = 900;

  /** Approximate TTS playback rate. Tune against real audio if needed. */
  const CHARS_PER_SECOND = 15;

  /** gpt-realtime audio tokens per second of audio. Tune if Apple usage drifts. */
  const REALTIME_TOKENS_PER_SECOND = 50;

  export function secondsRemaining(consumed: number): number {
    return Math.max(0, FREE_AI_SECONDS_CAP - consumed);
  }

  export function charsToSeconds(chars: number): number {
    if (chars <= 0) return 0;
    return Math.ceil(chars / CHARS_PER_SECOND);
  }

  export function realtimeTokensToSeconds(
    audioInputTokens: number,
    audioOutputTokens: number,
  ): number {
    const total = audioInputTokens + audioOutputTokens;
    if (total <= 0) return 0;
    return Math.ceil(total / REALTIME_TOKENS_PER_SECOND);
  }
  ```

- [ ] **Step 4: Run tests, verify pass.** Expected: PASS (4 tests).

- [ ] **Step 5: Add a DB debit helper with a miniflare test.**
  Append to `free-budget.ts`:
  ```ts
  import { eq, sql } from "drizzle-orm";
  import { user } from "@rishi/shared/schema";
  import type { createDb } from "../db/drizzle";

  /** Atomically add `seconds` to the user's consumed counter. */
  export async function debitFreeSeconds(
    db: ReturnType<typeof createDb>,
    userId: string,
    seconds: number,
  ): Promise<void> {
    if (seconds <= 0) return;
    await db
      .update(user)
      .set({ freeAiSecondsConsumed: sql`${user.freeAiSecondsConsumed} + ${seconds}` })
      .where(eq(user.id, userId));
  }

  /** Read consumed seconds for a user (0 if row missing). */
  export async function consumedFreeSeconds(
    db: ReturnType<typeof createDb>,
    userId: string,
  ): Promise<number> {
    const row = await db
      .select({ c: user.freeAiSecondsConsumed })
      .from(user)
      .where(eq(user.id, userId))
      .get();
    return row?.c ?? 0;
  }
  ```
  Write a miniflare D1 test (mirror `backfill.test.ts` bootstrap) asserting:
  insert a user, `debitFreeSeconds(db, id, 100)`, then
  `consumedFreeSeconds(db, id)` === 100; a second debit of 50 → 150.

- [ ] **Step 6: Run + commit.**
  ```bash
  git add workers/worker/src/billing/free-budget.ts workers/worker/src/billing/free-budget.test.ts
  git commit -m "feat(worker): free AI budget cap + debit helpers"
  ```

---

## Task 3: Gate + debit the TTS route

**Files:**
- Modify: `workers/worker/src/index.ts` (the `POST /api/audio/speech` handler, ~lines 466-524)
- Test: extend the existing audio-speech test
  (`workers/worker/src/audio-speech.test.ts`)

- [ ] **Step 1: Write failing tests.**
  Add cases to `audio-speech.test.ts`:
  - Pro user: request succeeds, counter NOT debited.
  - Free user with `consumed < 900`: request succeeds, counter debited by
    `charsToSeconds(text.length)`.
  - Free user with `consumed >= 900`: request returns `402`, body
    `{ error: "free_ai_exhausted" }`, OpenAI synth NOT called.
  Reuse the file's existing OpenAI mock + auth helpers. To set Pro vs free,
  follow how the file already distinguishes subscription state (it currently
  passes `requireActiveSubscription`); replace that assertion with the new gate.

- [ ] **Step 2: Run, verify fail.**
  Run: `pnpm --filter worker test audio-speech`. Expected: FAIL.

- [ ] **Step 3: Implement the gate + debit.**
  In the handler, remove the `requireActiveSubscription` middleware from this
  route and instead, after `requireAuth` resolves `userId`:
  ```ts
  const db = createDb(c.env.DB);
  const pro = await userHasPro(c.env, userId); // reuse the existing Pro check
  if (!pro) {
    const consumed = await consumedFreeSeconds(db, userId);
    if (secondsRemaining(consumed) <= 0) {
      return c.json({ error: "free_ai_exhausted" }, 402);
    }
  }
  // ... existing synth via experimental_generateSpeech ...
  if (!pro) {
    c.executionCtx.waitUntil(debitFreeSeconds(db, userId, charsToSeconds(text.length)));
  }
  ```
  `userHasPro` = whatever predicate `requireActiveSubscription` used internally;
  extract it to a small reusable function if it isn't already callable.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add workers/worker/src/index.ts workers/worker/src/audio-speech.test.ts
  git commit -m "feat(worker): meter TTS against free AI budget, 402 when spent"
  ```

---

## Task 4: Gate the realtime ephemeral key + debit the usage report

**Files:**
- Modify: `workers/worker/src/index.ts` (the ephemeral-key route used by
  `RealtimeVoiceSession`, and `POST /api/billing/realtime-usage`, ~lines 445-455)
- Test: `workers/worker/src/billing/realtime-usage` route test (create or extend)

- [ ] **Step 1: Write failing tests.**
  - Ephemeral-key route: free user with `consumed >= 900` → `402`
    `{ error: "free_ai_exhausted" }`, no key minted; Pro user → key minted, no debit.
  - `realtime-usage` route: free user posting `{audioInputTokens, audioOutputTokens}`
    debits `realtimeTokensToSeconds(...)`; Pro user does not debit the free pool
    (Stripe metering via `meterFromContext` is unchanged for both).

- [ ] **Step 2: Run, verify fail.** Run the realtime route test. Expected: FAIL.

- [ ] **Step 3: Implement.**
  Ephemeral-key route: after auth, if `!pro` and `secondsRemaining(consumed) <= 0`,
  return `402` before minting the key.
  `realtime-usage` route (currently calls `parseRealtimeUsageBody` then
  `meterFromContext`): after a successful parse, when `!pro`, also
  ```ts
  c.executionCtx.waitUntil(
    debitFreeSeconds(db, userId,
      realtimeTokensToSeconds(parsed.usage.audioInputTokens, parsed.usage.audioOutputTokens)),
  );
  ```
  Keep the existing `meterFromContext(...)` call untouched.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add workers/worker/src/index.ts workers/worker/src/billing
  git commit -m "feat(worker): gate realtime key + debit voice usage against free budget"
  ```

---

## Task 5: Expose remaining seconds in the entitlement payload

**Files:**
- Modify: the entitlement handler from Pre-flight Step P2 (e.g.
  `workers/worker/src/billing/apple-me.ts`, response builder ~lines 27-95)
- Test: that handler's existing test (e.g. `apple-me` test) or `backfill.test.ts` sibling

- [ ] **Step 1: Write failing test.**
  Assert the entitlement response for a free user with `consumed = 200` includes
  `freeAiSecondsRemaining: 700`; for a Pro user includes
  `freeAiSecondsRemaining: 900` (Pro ignores it client-side, but return the cap
  for consistency).

- [ ] **Step 2: Run, verify fail.** Expected: FAIL.

- [ ] **Step 3: Implement.**
  In the response type and builder, add:
  ```ts
  freeAiSecondsRemaining: pro
    ? FREE_AI_SECONDS_CAP
    : secondsRemaining(await consumedFreeSeconds(db, userId)),
  ```
  Import from `./free-budget`.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add workers/worker/src/billing
  git commit -m "feat(worker): return freeAiSecondsRemaining in entitlement payload"
  ```

---

## Task 6: Decode + cache remaining seconds in EntitlementService

**Files:**
- Modify: the Swift endpoint DTO from Pre-flight Step P1 (under
  `apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/`)
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Service/EntitlementService.swift`
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Service/` (match existing EntitlementService test file)

- [ ] **Step 1: Write failing test.**
  ```swift
  @Test("snapshot exposes decoded freeAiSecondsRemaining")
  func decodesRemaining() async {
    // Inject a stubbed worker client returning freeAiSecondsRemaining = 600.
    // Match the existing EntitlementService test's stubbing pattern.
    let service = makeService(stubbingRemaining: 600, hasPro: false)
    _ = await service.refresh()
    #expect(await service.snapshot().freeAiSecondsRemaining == 600)
  }
  ```

- [ ] **Step 2: Run, verify fail.**
  Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter EntitlementService`
  Expected: FAIL (no such property).

- [ ] **Step 3: Implement.**
  Add `freeAiSecondsRemaining: Int?` to the response `Decodable` struct (key
  `freeAiSecondsRemaining`). Add `freeAiSecondsRemaining: Int` to the service's
  snapshot value type (default `0`). Persist it to the same UserDefaults cache
  used for `hasPro`, and restore it on cold start (mirror the `hasPro` cache
  code exactly). When the field is absent, treat as `0` (post-resolve only).

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add apps/apple/Packages/RishiBilling apps/apple/Packages/RishiAPI
  git commit -m "feat(apple): decode + cache freeAiSecondsRemaining in EntitlementService"
  ```

---

## Task 7: AppGate.resolve takes freeAiSecondsRemaining

**Files:**
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/Entitlements/AppGate.swift`
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/Entitlements/AppGateTests.swift`

- [ ] **Step 1: Write failing tests.**
  ```swift
  @Test("free with budget remaining gets the app")
  func freeWithBudget() {
    #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true,
      entitlementResolved: true, level: .free, freeAiSecondsRemaining: 120) == .app)
  }
  @Test("free, resolved, budget spent gets the paywall")
  func freeSpent() {
    #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true,
      entitlementResolved: true, level: .free, freeAiSecondsRemaining: 0) == .paywall)
  }
  @Test("free, spent, NOT resolved stays loading")
  func freeSpentUnresolved() {
    #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true,
      entitlementResolved: false, level: .free, freeAiSecondsRemaining: 0) == .loading)
  }
  @Test("pro ignores remaining")
  func proIgnores() {
    #expect(AppGate.resolve(authProbeComplete: true, isSignedIn: true,
      entitlementResolved: false, level: .pro, freeAiSecondsRemaining: 0) == .app)
  }
  ```
  Update the existing `paywallForResolvedFree` / `loadingWhileEntitlementUnresolved`
  cases to pass `freeAiSecondsRemaining: 0` (so they keep asserting the same
  outcomes under the new signature).

- [ ] **Step 2: Run, verify fail.**
  Run: `swift test --package-path apps/apple/Packages/RishiBilling --filter AppGate`
  Expected: FAIL (signature mismatch / new behavior).

- [ ] **Step 3: Implement.**
  ```swift
  public static func resolve(
      authProbeComplete: Bool,
      isSignedIn: Bool,
      entitlementResolved: Bool,
      level: EntitlementLevel,
      freeAiSecondsRemaining: Int
  ) -> AppGate {
      guard authProbeComplete else { return .loading }
      guard isSignedIn else { return .signedOut }
      if level == .pro { return .app }
      guard entitlementResolved else { return .loading }
      return freeAiSecondsRemaining > 0 ? .app : .paywall
  }
  ```

- [ ] **Step 4: Run, verify pass.** Expected: PASS (all cases).

- [ ] **Step 5: Commit.**
  ```bash
  git add apps/apple/Packages/RishiBilling
  git commit -m "feat(apple): AppGate gates free users on remaining AI budget"
  ```

---

## Task 8: Wire remaining into RootView's AppGate call

**Files:**
- Modify: `apps/apple/rishi/rishi/RootView.swift` (the `AppGate.resolve` call in
  `realBodyContent`, ~lines 104-109)

- [ ] **Step 1: Update the call site.**
  Read the cached remaining off the entitlement reconciler/service the same way
  `level` is read, and pass it:
  ```swift
  switch AppGate.resolve(
      authProbeComplete: authProbeComplete,
      isSignedIn: currentUser != nil,
      entitlementResolved: entitlementResolved,
      level: deps.entitlementReconciler.level,
      freeAiSecondsRemaining: deps.entitlementReconciler.freeAiSecondsRemaining
  ) { ... }
  ```
  If the reconciler does not yet carry `freeAiSecondsRemaining`, add it as an
  observed property fed by the same bridge that feeds `setServer(level)` (see
  `EntitlementServerBridge` and `ServiceGraphFactory` seeding). Mirror the
  existing `level` plumbing exactly so Observation re-renders when it changes.

- [ ] **Step 2: Build (orchestrator gate).**
  Full `xcodebuild` per the header. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**
  ```bash
  git add apps/apple/rishi/rishi/RootView.swift apps/apple/Packages/RishiBilling
  git commit -m "feat(apple): feed remaining AI budget into the app gate"
  ```

---

## Task 9: Gate the AI feature buttons on pro || remaining > 0

**Files:**
- Modify: `apps/apple/rishi/rishi/Reader/EPUBReaderDestination.swift` (`onReadAloud`, ~lines 67-80)
- Modify: `apps/apple/rishi/rishi/Reader/PDFReaderDestination.swift` (`onReadAloud`, ~lines 62-80)
- Modify: `apps/apple/rishi/rishi/Voice/ReaderVoiceEntry.swift` (`presentVoice`, ~lines 43-77)

- [ ] **Step 1: Change each gate.**
  Each site currently does `if level == .pro { start } else { onRequestPaywall(...) }`.
  Change the predicate to allow free users with budget:
  ```swift
  let snap = await entitlementService.snapshot()
  let allowed = snap.level == .pro || snap.freeAiSecondsRemaining > 0
  if allowed { /* start feature */ } else { onRequestPaywall("Read Aloud") }
  ```
  Use the same snapshot the site already takes; do not add a second fetch.

- [ ] **Step 2: Build (orchestrator gate).** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**
  ```bash
  git add apps/apple/rishi/rishi/Reader apps/apple/rishi/rishi/Voice
  git commit -m "feat(apple): allow free AI use while budget remains"
  ```

---

## Task 10: Handle worker 402 in the app AI paths (defense-in-depth)

**Files:**
- Modify: `apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSStreamer.swift`
  (and/or the `ReadAloudController` that consumes it)
- Modify: `apps/apple/Packages/RishiVoice/Sources/RishiVoice/Service/RealtimeVoiceSession.swift`
  (the ephemeral-key fetch path, ~line 170)
- Test: the package test targets for RishiAudio / RishiVoice

- [ ] **Step 1: Write failing tests.**
  Stub the worker client to return HTTP `402` with `{ "error": "free_ai_exhausted" }`.
  Assert the TTS stream surfaces a typed `.freeAiExhausted` error (not a generic
  failure) and that the realtime start throws the same typed error.

- [ ] **Step 2: Run, verify fail.**
  Run: `swift test --package-path apps/apple/Packages/RishiAudio` (and RishiVoice).
  Expected: FAIL. (If a package transitively depends on Readium and cannot build
  on host, gate via per-file typecheck + the orchestrator xcodebuild instead.)

- [ ] **Step 3: Implement.**
  Map a `402` with that body to a dedicated error case
  (`enum AIBudgetError { case freeAiExhausted }`) in both streamers. The UI
  layer (reader destinations) catches it and calls `onRequestPaywall(...)`,
  reusing the Task 9 callback.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add apps/apple/Packages/RishiAudio apps/apple/Packages/RishiVoice apps/apple/rishi
  git commit -m "feat(apple): route worker 402 free-budget errors to the paywall"
  ```

---

## Task 11: Paywall messaging variant for the spent pool

**Files:**
- Modify: `apps/apple/Packages/RishiBilling/Sources/RishiBilling/UI/PaywallView.swift`
  (the `hero` block, ~lines 148-162)
- Modify: `apps/apple/rishi/rishi/Billing/PaywallGateView.swift` (pass the trigger reason)
- Test: `apps/apple/Packages/RishiBilling/Tests/RishiBillingTests/PaywallUITests.swift`

- [ ] **Step 1: Write failing test.**
  Assert that when constructed with a `.budgetExhausted` reason, the paywall's
  headline string equals "You've used your free AI minutes" (or the agreed
  copy), and with `.generic` it equals "Rishi Pro".

- [ ] **Step 2: Run, verify fail.** Expected: FAIL.

- [ ] **Step 3: Implement.**
  Add `enum PaywallReason { case generic, budgetExhausted }` and a parameter
  (default `.generic`) on the relevant `PaywallView` init; the `hero` title +
  subtitle switch on it. `PaywallGateView` passes `.budgetExhausted` (since the
  whole-app gate only fires once the pool is spent). Keep the trial-forward CTA
  from the shipped change intact.

- [ ] **Step 4: Run, verify pass.** Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add apps/apple/Packages/RishiBilling apps/apple/rishi/rishi/Billing
  git commit -m "feat(apple): budget-exhausted paywall copy variant"
  ```

---

## Final verification (orchestrator)

- [ ] Full `xcodebuild` (iPhone 17, isolated derivedDataPath) → `** BUILD SUCCEEDED **`.
- [ ] `swift test --package-path apps/apple/Packages/RishiBilling` green.
- [ ] `pnpm --filter worker test` green (free-budget, audio-speech, realtime, entitlement).
- [ ] Manual: a fresh free account can read + use AI, the entitlement payload
  shows the countdown decreasing, and the whole-app paywall appears once it hits
  zero; a Pro account is never affected.
- [ ] Dispatch a final code-reviewer subagent over the whole diff before merge.

## Tuning notes (post-launch)

- `CHARS_PER_SECOND` (15) and `REALTIME_TOKENS_PER_SECOND` (50) are estimates;
  validate against real audio durations and adjust. They affect only how fast
  the pool drains, not correctness.
- `FREE_AI_SECONDS_CAP` (900) is the single product lever for the taste size.

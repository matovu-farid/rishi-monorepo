# Phase B Plan — TTS / AI-Chat E2E Audit (P7)

**Tester:** B-T7 — Tester ID range **B086–B100** (max 5 findings × 4 specs = 20; cap to 15 by range).
**Files in scope:**
- `apps/rishi-electron/e2e/ai-chat.spec.ts` (60 LOC, 3 tests)
- `apps/rishi-electron/e2e/tts.spec.ts` (67 LOC, 4 tests)
- `apps/rishi-electron/e2e/tts-page-navigation.spec.ts` (1560 LOC, ~12 tests)
- `apps/rishi-electron/e2e/read-aloud-from-selection.spec.ts` (271 LOC, 3 tests)

---

## 1. Skip list

- The test `read-aloud-from-selection.spec.ts` line 84 contains a runtime `test.skip(true, 'No paragraphs published…')` *inside* the test body — this is a soft skip on a fixture race, NOT a `test.skip(...)` declaration. Treat as a flake-prone test, not a parity gap. Same pattern at L164–167 and L230–233.
- No suite-level `test.skip(...)` declarations exist in any of the 4 specs (grep confirmed). All tests will execute when invoked.
- ai-chat spec uses `[aria-label="Start voice chat"]` but does **not** exercise mic permission / `getUserMedia` paths — the only assertions are launcher visibility and the premium-gate dialog. Voice mic permission paths are entirely uncovered here; record as parity gap, not skip.

---

## 2. Per-file audit checklist

### 2.1 `e2e/ai-chat.spec.ts` (B086–B089)

- **Shared app fixture (L18–35):** `beforeAll` launches Electron and opens one book; all 3 tests share `bookPage`. If test 2 (premium dialog) leaves the dialog open and `closeOverlays` (L38) doesn't dismiss it, test 3 will fail spuriously. Check `closeOverlays` in `helpers/electron-app.ts` for dialog-content dismissal.
- **Selector specificity (L42, 48, 51):** `.first()` is used on `[aria-label="Start voice chat"]` — implies the locator matches multiple nodes. Investigate: is the orb rendered in both a portal and inline, or is `.first()` a bandaid for an unstable DOM?
- **No mic permission path tested.** `navigator.permissions.query({name:'microphone'})` / `getUserMedia` flows are never asserted. The premium dialog is the only branch covered — what happens when an authenticated user clicks "Start voice chat" and mic permission is denied/blocked? Record as parity gap (B086 candidate).
- **No TTS+voice-chat collision test.** If TTS is playing and the user clicks "Start voice chat", does TTS pause? There is no cross-feature test in this spec or in `tts.spec.ts`. Check the planned spec at `docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md` for the intended contract — the absence of a test for it is a finding-class gap (B087 candidate).
- **Premium-dialog "Sign in" assertion is text-based** (L51) — `'text=Sign in'`. Localization-fragile and may collide with header sign-in button if the dialog overlay leaks. Practice violation candidate.
- **No state-after-error coverage:** if the dialog open IPC fails, no assertion checks the launcher remains clickable. Practice/parity gap.

### 2.2 `e2e/tts.spec.ts` (B090–B093)

- **No mocked TTS service installed.** This spec never calls `installSilentMockTts`. The only test that would hit the network (`Play without auth opens premium dialog`, L59) is short-circuited by the auth gate. **Verify:** if a dev-bypass header or future test bypass changes the auth gate, will `Play` start a real network request? Hardened-against-future-regression: should install the mock anyway (B090 candidate, practice).
- **`Stop is disabled when nothing is playing` (L54–57)** asserts a state-after-error invariant only partially — it does not cover Stop disabled after PLAY→ERROR (e.g., TTS rejects). Coverage gap (B091).
- **No assertion that Play button label flips to Pause** after a successful play. Not testable here without mocking TTS — but the absence of the success path leaves the orb's primary user-facing behavior untested in this spec (delegated to `tts-page-navigation.spec.ts`). Record parity link.
- **Shared `bookPage`** (L33–39) is re-opened in each `beforeEach` via `openBook`, but `app` and the imported book are shared in `beforeAll`. If a prior test leaves the player in `playing` state, `Stop is disabled` will fail. Order-coupling risk.
- **CSS-style assertion** at L43 (`toHaveCSS('position','fixed')`) tests an implementation detail (positioning strategy), not user-visible behavior. Should assert the orb's bounding box is in the viewport's bottom-right quadrant instead. Practice violation (B092).
- **No state-after-error test for premium dialog** — if "Maybe later" fails to close (network/IPC error), no fallback is asserted. The L64–65 sequence assumes success. (B093 candidate).

### 2.3 `e2e/tts-page-navigation.spec.ts` (B094–B098) — highest density

- **Inline mock-TTS at L81–116, L162–214, et al.** Six tests use `installMockTts` from `player-helpers`; others inline a hand-built WAV. Two patterns for the same thing — divergence risk. Cite as practice (B094).
- **Arbitrary sleeps (timing-based assertions):**
  - L123 `waitForTimeout(150)` — load-state pause race. Comment justifies it; the test asserts pause delay < 300 ms (L133). Borderline acceptable because the wait is *less than* the asserted bound, but fragile under loaded CI.
  - L646 `waitForTimeout(300)`, L1010 `waitForTimeout(6000)`, L1194 `waitForTimeout(2000)` — large arbitrary waits in BUG-marked tests (T1, T2). These mask races rather than expose them. Practice violation (B095).
- **Hand-built WAVs (L95–99, L173–193, etc.):** repeated byte-array literal for RIFF headers — extract to a `helpers/wav-fixtures.ts`. Practice violation (B096).
- **Test isolation: `import fresh book per test`** comment at L23–25 is the *right* pattern; verify it actually does so in all 12 tests. Tests labeled T1/T2/T3 (L972, L1080, L1233) appear to share state across waitForTimeout-driven sequences — confirm.
- **State-after-error coverage:**
  - The "audio bleed" test (L61) asserts pause happens BEFORE TTS resolves; good. But there is no test for *TTS resolves with an error* (`requestAudio` rejects) — does the player return to a usable state, or get stuck in `loading`? Coverage gap (B097).
  - L484 ("stale blob not played") — verify the assertion actually catches the bug (mutation test: temporarily remove the staleness guard, confirm test fails).
- **Parallel TTS+chat collisions:** This spec is TTS-only. The cross-feature interaction (TTS active, then voice-chat triggers) is uncovered. Cross-reference §2.1 parity gap.
- **Pause-log monkey-patch (L90–94)** replaces `audioElement.pause` — if any other test in the suite shares this audio element (per-window now, per Phase 3), the patch leaks. Confirm window isolation. Practice/lifecycle.
- **`installMockTts` cleanup:** several tests call `setTestTtsService(null)` in teardown (L137–139); not all do. Grep for missing teardown — B098 candidate.

### 2.4 `e2e/read-aloud-from-selection.spec.ts` (B099–B100)

- **Auth bypass via store setState (L70–81)** — the test stuffs a fake user directly into `authStore`. This bypasses `requireAuth` but does NOT exercise the real sign-in flow. Documented as intentional in the file header; fine for this spec, but ensure no other spec relies on the same bypass (collision risk).
- **`test.skip(true, ...)` inside test bodies** (L97, L164, L230) — soft-skips on fixture race. These hide flakiness behind a green run. The skip message is logged but a CI run that hits all three soft-skips would report 3/3 passing tests with zero assertions. Practice/coverage gap (B099).
- **TTS log assertion** at L142 `expect(log.length).toBeGreaterThan(0)` — only asserts request count, not request *contents* (CFI, text, voice). A regression that requests audio for the wrong selection would still pass. Coverage gap (B100).
- **IPC test (L198–270)** uses a window CustomEvent rather than a real `webContents.send` from main. The file header admits this — it tests `handleReadAloudFrom` not the full IPC channel. The right-click code path is therefore NOT covered E2E. Parity gap.
- **Mock TTS via `installSilentMockTts`** — confirm this helper returns a silent WAV; if it returns null/empty buffer, downstream `audio.play()` may throw and the player can wedge in `loading`. Verify helper.
- **Empty-store assertion (L244)** `storeBefore` toBeNull — the selectionStore state shape may have changed (`current` could be `undefined`). Brittle if the store contract shifts.

### 2.5 Cross-cutting themes (file all under B086–B100; pick one finding slot)

- **Real-network dependencies:** Only `tts.spec.ts` lacks mock installation (auth gate is the de-facto guard). Recommend a global Playwright fixture that auto-installs `installSilentMockTts` on every reader page open.
- **Parallel TTS+chat state collisions:** No test in scope covers (a) voice chat starting while TTS plays, (b) TTS starting while voice chat is active. This is the documented design intent (see `docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md`) — record as the dominant cross-spec gap.
- **Mic permission paths untested anywhere.** ai-chat spec stops at the premium dialog; no signed-in mic flow exists. Record as parity gap (note: per `project_macos_mic_entitlements.md`, signed builds required; E2E may legitimately not be able to assert mic acquisition — flag accordingly in `parity-gaps.md`).
- **Playback-timing assertions:** large `waitForTimeout(6000)` in T1 (L1010) is the worst offender. Prefer `expect.poll(...)` against `readPlayerSnapshot`.

---

## 3. Tester ID range

**B086–B100** (Tester B-T7). 15 IDs across 4 specs = up to 5 per spec but cap total ≤ 15. Alternate `reviewer1_agent_type` by ID parity per pilot §4.4 (odd → `team-reviewer`, even → `feature-dev:code-reviewer`).

---

## 4. Test commands

### Build prerequisite (REQUIRED — `out/main/index.js` must exist)

```bash
pnpm --filter rishi-electron build
```

### Run a single spec

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/ai-chat.spec.ts
pnpm test:e2e e2e/tts.spec.ts
pnpm test:e2e e2e/tts-page-navigation.spec.ts
pnpm test:e2e e2e/read-aloud-from-selection.spec.ts
```

### Run a single test by name

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/tts-page-navigation.spec.ts -g "entering loading state pauses"
```

### Reviewer-1 flake check (≥3 runs)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/tts-page-navigation.spec.ts -g "<test name>" || echo "run $i: FAIL"; done
```

### Discovery dry-run

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e --list e2e/tts-page-navigation.spec.ts
```

---

## Closing notes

- Strongest signal: `tts-page-navigation.spec.ts` has 12 dense tests with timing-based assertions and inline WAV fixtures — most B094–B098 finding candidates live here.
- Weakest signal: `ai-chat.spec.ts` (3 thin tests) — most output will land in parity-gaps.md (mic, TTS+chat collision).
- Soft-skips (`test.skip(true,…)` inside bodies) in `read-aloud-from-selection.spec.ts` are the most insidious — a green CI may mean zero coverage.

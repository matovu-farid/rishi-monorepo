# Test Infra Backlog — Tester B-T7 (TTS / AI-Chat)

## 1. Global Playwright fixture to auto-install silent mock TTS
- Today, `installSilentMockTts(bookPage)` is called manually by some
  tests (`read-aloud-from-selection.spec.ts:66`,
  `tts-page-navigation.spec.ts` various) and *not* called by others
  (`tts.spec.ts`). The latter currently relies on the auth gate as a
  network guard. A future dev-bypass header (per
  `reference_dev_bypass.md`) or a test-only auth bypass could change
  that overnight.
- Proposal: add a Playwright fixture (`test.extend({ bookPage: async ...
  }) }`) that calls `installSilentMockTts` immediately after every
  `openBook`. Opt-out via fixture parameter for tests that need a real
  TTS service.
- Impact: removes a class of accidental-real-network regressions and
  unifies the two patterns currently in use.

## 2. Cross-feature TTS + voice-chat helper
- Per B087, there is no helper for sequencing TTS + voice chat. Add:
  - `helpers/voice-chat.ts: injectFakeAuthUser(page)` (extracted from
    `read-aloud-from-selection.spec.ts:70-81`)
  - `helpers/voice-chat.ts: startVoiceChat(page)` — click launcher + wait
    for session-active selector / store flag.
  - `helpers/voice-chat.ts: endVoiceChat(page)` — wait for session-end +
    `playerStore` resume.
- Once these exist, the cross-feature tests in B087 are 10-15 lines each.

## 3. WAV-fixture helper extraction
- Inline RIFF headers at `tts-page-navigation.spec.ts:95-99, 173-193`,
  and elsewhere. Extract to `helpers/wav-fixtures.ts`:
  - `buildSilentWav({ durationMs, sampleRate })`
  - `buildDelayedWavService({ delayMs, wavBytes })` — wraps the inline
    Promise-with-setTimeout pattern at L102-108.
- Saves ~120 LOC and centralizes the format choice.

## 4. `expect.poll` helper for "state does NOT change" assertions
- T2 (`tts-page-navigation.spec.ts:1194-1212`) needs to assert "page CFI
  did not change for 2s." Native Playwright has no idiom for this; add:
  - `helpers/assertions.ts: expectStable(fn, { duration, intervalMs })`
    — polls `fn()` over `duration`, fails if value ever differs from the
    initial.
- This is the correct shape for every "no unwanted action happens within
  N seconds" assertion in the suite.

## 5. Mic-permission stub helper
- For B086. Add `helpers/permissions.ts: stubMicPermission(page, status:
  'granted' | 'denied' | 'prompt')` and
  `helpers/permissions.ts: stubGetUserMedia(page, outcome: ...)`. Both
  use `page.addInitScript`. This unblocks signed-in voice-chat tests
  without depending on real OS permission grants or signed builds.

## 6. Soft-skip lint rule
- Per B099. Add an ESLint rule (or a CI grep check) that flags
  `test.skip(true, ...)` inside test bodies in `e2e/**`. The legitimate
  use cases (environment capability) are rare enough to whitelist.

## 7. TTS log helper: assert-on-contents shape
- Per B100. `readTtsLog` already returns the rich shape (cfiRange,
  priority). Add a convenience:
  - `helpers/player-helpers.ts: expectTtsRequestedCfi(page, cfi,
    options?: { priority?, timeout? })` — polls the log until a request
    matching the CFI appears, fails with a diagnostic listing all
    requests.
- Replaces both `expect(log.length).toBeGreaterThan(0)` sites in
  `read-aloud-from-selection.spec.ts`.

## 8. Per-window isolation audit for `tts-page-navigation.spec.ts`
- The L23-25 comment claims "each test imports a fresh book and opens
  its own window." Verify all 12 tests honor this. The
  `audioElement.pause` monkey-patch at L90-94 leaks across tests if any
  share a window.
- Mechanical check: every test must call `importBook` + `openBook` and
  the resulting `bookPage` must not be assigned to an outer-scope
  variable. A small grep in CI can enforce this.

## 9. Main-process IPC harness for right-click menu coverage
- Per parity-gaps §3. Add a helper that invokes
  `electronApp.evaluate(({ BrowserWindow }, { channel, payload }) => {
    BrowserWindow.getAllWindows()[0].webContents.send(channel, payload)
  })`. This lets `read-aloud-from-selection.spec.ts` exercise the real
  IPC path instead of the renderer-side CustomEvent substitute.

## 10. Flake-check runner per Reviewer-1 protocol
- Plan §4 mentions a 3-run flake loop. Codify as
  `scripts/flake-check.sh <spec> <grep>` that runs N times and reports
  pass/fail counts. Useful for B095 candidates and for any test using
  `waitForTimeout`.

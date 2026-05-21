# Parity Gaps — Tester B-T7 (TTS / AI-Chat)

Specs audited:
- `apps/rishi-electron/e2e/ai-chat.spec.ts`
- `apps/rishi-electron/e2e/tts.spec.ts`
- `apps/rishi-electron/e2e/tts-page-navigation.spec.ts`
- `apps/rishi-electron/e2e/read-aloud-from-selection.spec.ts`

## 1. Voice chat — mic permission paths uncovered (B086)
- `ai-chat.spec.ts` exercises only launcher visibility + premium gate.
- No signed-in path; no `getUserMedia` rejection (denied / no-device);
  no `permissions.query` `prompt` branch.
- Per `project_macos_mic_entitlements.md`, real mic acquisition needs a
  signed build, but the *handling* of permission denial is renderer JS
  and is stubbable via `page.addInitScript`.
- Filed as B086.

## 2. TTS ↔ voice-chat collision uncovered (B087)
- Documented intent at
  `docs/superpowers/plans/2026-05-20-preserve-tts-position-during-voice-chat-plan.md`
  requires TTS to pause when voice chat starts and resume after it ends,
  preserving position.
- No spec in scope sequences PLAY (TTS) → click "Start voice chat" →
  assert `playerStore.playingState` is `paused.*` and
  `audioElement.paused === true`. No reverse-direction test either.
- Filed as B087.

## 3. Read-aloud-from-selection IPC channel not covered E2E
- `read-aloud-from-selection.spec.ts:198-270` substitutes a renderer-side
  CustomEvent (`rishi:readAloudFromSelection`) for the real
  `webContents.send('reader:readAloudFromSelection', ...)`. The file
  header acknowledges this.
- Result: the right-click → main-process menu → IPC → renderer subscriber
  → `handleReadAloudFrom` chain is partially uncovered. A regression
  isolated to `electron/main/menus/...` or the preload bridge would
  ship green.
- Recommendation: add a Playwright-driven main-process IPC trigger (via
  `electronApp.evaluate(({ BrowserWindow }) => ...)`) to fire
  `webContents.send` from the real source. Not filed as a finding because
  the renderer half is covered and the gap is documented inline.

## 4. TTS `Play` success path not asserted in `tts.spec.ts`
- `tts.spec.ts` covers Stop-disabled (L54), orb expand (L46), and the
  premium dialog (L59). The `Play → Pause` label flip after a successful
  play is delegated to `tts-page-navigation.spec.ts`.
- This is acceptable as a coverage division, but a one-line note here so
  future spec-pruners do not collapse `tts.spec.ts` into nothing thinking
  it has redundant coverage.

## 5. Mic permission anywhere
- Cross-cuts every voice-chat-adjacent spec. Recorded once in B086; not
  duplicated.

## 6. `installSilentMockTts` not installed in `tts.spec.ts`
- Auth gate is the de-facto network guard. If a future dev-bypass header
  or test-only auth bypass is added, the spec could start hitting real
  TTS. See practices-audit B-T7 for the recommended global fixture.

## 7. Soft-skips in `read-aloud-from-selection.spec.ts`
- L97 / L165 / L231: `test.skip(true, ...)` inside test bodies turns
  fixture-race failures into greens. Filed as B099.

# Phase 1 — Premium Auth Gating: REVIEW

Date: 2026-05-22
Reviewer: reviewer agent
Diff range: `354b6e7b..HEAD` (5 implementation commits)

---

## Verdict

**SHIP-WITH-FIXES.**

Two real bugs block ship as-is. The shared package, mobile hook, sheet
component, and authStore slice are clean. Electron rewire is correct on the
production code side, but the rewire missed one stale test assertion, and the
mobile gating has a real coverage gap (PDF / MOBI / DJVU reader screens
trigger TTS without going through `useRequireAuth`).

---

## Critical findings

### 1. 🔴 Block ship — Electron test fails (stale `'chat'` key)

`apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts:110`

```ts
expect(params.requireAuth).toHaveBeenCalledWith('chat', expect.any(Function))
```

The production call site at
`apps/rishi-electron/src/renderer/src/hooks/reader/useCommonMenuHandlers.ts:62`
was correctly renamed `'chat' → 'ai-chat'` (per ARCH §2.4), but this test's
expectation was not updated. Running the suite confirms the failure:

```
× openChat calls requireAuth("chat", ...) and toggles chatPanelOpen
  AssertionError: expected "vi.fn()" to be called with arguments: [ 'chat', Any<Function> ]
  Received: 1st vi.fn() call: [ "ai-chat", [Function anonymous] ]
```

GREEN.md §1 reports only the `features.test.ts` + new dialog suite were run
on the electron side, so this regression was not caught. It will fail the
moment the full electron test suite is run.

**Fix:** update line 110 to `'ai-chat'` (and the `it` description on line 103
from `'requireAuth("chat", ...)'` to `'requireAuth("ai-chat", ...)'`).

---

### 2. 🔴 Block ship — TTS gate missing on three of five reader formats

ARCH listed 7 mobile call sites and the coder wired all 7. **However the
research-listed-7 set silently ignored the per-format reader screens** — TTS
on PDF / MOBI / DJVU readers is initiated from those screens' own
`handleToggleTTS`, not from `app/reader/[id].tsx` (the EPUB-only reader).
None of them gate:

- `apps/mobile/app/reader/pdf/[id].tsx:389` — `send({ type: 'PLAY_FROM', ... })` is called from the PDF "read-aloud-from-selection" handler with no `requireTTS` wrap.
- `apps/mobile/app/reader/mobi/[id].tsx:346-364` — `handleToggleTTS` calls `sendFn({ type: 'PLAY' })` directly.
- `apps/mobile/app/reader/djvu/[id].tsx:199-220` — same pattern, direct `sendFn({ type: 'PLAY' })`.

A signed-out user opening a PDF, MOBI or DJVU and tapping the toolbar "Read
aloud" button bypasses the gate entirely. The cross-format parity claim in
the design doc (§Done when: "TTS button on a signed-out mobile session shows
the sheet") only holds for EPUB.

Note: `TTSControls` does gate its own `PLAY`, but those controls only render
when `playingState !== 'idle'` (TTSControls.tsx:40) — i.e. only AFTER the
initial PLAY has already been dispatched from the reader screen. So the bottom
controls' gate never fires on the initial-start path for these formats.

**Fix:** add `useRequireAuth('tts')` to each of pdf/mobi/djvu reader screens
and wrap the `sendFn({ type: 'PLAY' })` / `send({ type: 'PLAY_FROM', ... })`
calls. Same pattern as `app/reader/[id].tsx:574-585`. The EPUB selection-based
`handleReadFromSelection` at `app/reader/[id].tsx:362-403` is also un-gated,
worth wrapping in the same pass for consistency.

(I would have listed this 🟡 if it were one format, but it's three out of five
formats that ship today and all of them have a working pre-Phase-1 TTS path
that the gate was supposed to cover. The user-visible effect is "the sign-in
sheet shows for EPUBs but not PDFs" — a parity bug.)

---

## Worth checking (lower confidence, not blocking)

### A. 🟡 Lost user input on signed-out send

`apps/mobile/components/ChatInput.tsx:43` clears `setText('')` *before*
invoking `onSend(trimmed)`. In `app/chat/[bookId].tsx:305`, `onSend` is now
`(text) => requireAIChat(() => void handleSend(text))`. For a signed-out user
who types a question and taps send:

1. ChatInput clears the input box.
2. `requireAIChat` opens the premium sheet.
3. User dismisses the sheet (didn't want to sign in).
4. The question they typed is gone.

This is a regression introduced by Phase 1 (pre-gate, the message would have
been sent — clearing was fine). Suggested fix: in `ChatInput.handleSend`,
only clear when the action commits, or — simpler — have the gated wrapper
in `chat/[bookId].tsx` re-populate the input on dismiss. Easiest: pass the
trimmed text into the action and only clear after gate passes (move
`setText('')` into the success path).

### B. 🟡 Out-of-scope changes bundled into commit `8a4e30fb`

The commit subject says "wire premium gate to TTS, voice, AI chat call sites",
but the diff also contains:

- `apps/mobile/app/reader/[id].tsx`: changed `useFileSystem` import from
  `@epubjs-react-native/expo-file-system` → `@/lib/epub/file-system-adapter`
  (line 5).
- `apps/mobile/app/reader/[id].tsx:193-196`: new `readerDefaultTheme` `useMemo`
  to fix an unrelated infinite-render loop.
- `apps/mobile/app/chat/[bookId].tsx`: testID renames
  (`chat-screen` → `screen-chat-detail`) and a new `messageIndexById` Map for
  E2E indexing.
- `apps/mobile/app/(tabs)/chat.tsx`: testID renames
  (`new-conversation-button` → `chat-new-conversation-btn`).

These look like incidental fixes / E2E plumbing that drifted into the gating
commit. Not bugs, but they violate atomic-commit hygiene and make
`git revert` of the gating change unsafe. Worth pulling out into a separate
chore commit if there's time before merge.

---

## Confirmed correct

- `packages/shared/src/auth-gating/{types,featureCopy,shouldGate,index}.ts` — pure, no React import, FEATURE_COPY exhaustive over the `PremiumFeature` union, exports clean.
- `featureCopy.ts` — every entry's title starts with `'Sign in to '`, body ends with `.`, copy strings match ARCH §1.2 (`'voice-input'` shares copy with `'voice-chat'` as intended).
- `packages/shared/package.json` + `packages/shared/src/index.ts` — `./auth-gating` subpath export added, root barrel re-exports.
- `useRequireAuth` cold-start behaviour — optimistic pass-through when `!authHydrated` is correct given lib/api.ts 401 handler; reactively re-creates the callback when `authHydrated` flips. Stable across re-renders (test 4 covers it).
- `authStore` slice — `premiumGateOpen`, `premiumGateFeature`, `openPremiumGate`, `closePremiumGate` initial state + setters wired correctly; not persisted (right — these are transient UI state).
- `PremiumFeatureSheet` — error filter `/cancel|dismiss/i` matches the only two cancel-flavoured strings `lib/auth.ts` can throw (`Sign-in cancelled or dismissed (type=cancel|dismiss)`) without matching the security-relevant strings (`state mismatch`, `missing state`). Filter is correctly narrow.
- `PremiumFeatureSheet` — `signIn(provider)` provider arg matches `lib/auth.ts:53` signature (`'google' | 'apple' | 'password'`). Platform-dispatch (`ios → apple`, `android → google`) consistent with electron's openSignIn.
- `PremiumFeatureSheet` — backdrop `pressBehavior="close"` set; `onClose={closeGate}` on the sheet → swipe-to-dismiss clears store state.
- `PremiumFeatureSheet` — `useSharedValue` inside the component scope (line 55). No Reanimated hook at module scope.
- `PremiumFeatureSheet` — `Animated.View` correctly wraps the CTA, shake only triggers on non-cancel error.
- Electron `features.ts` — sources `title`/`description` from `FEATURE_COPY.title`/`.body`; keeps electron-only `icon` + `bullets`; covers all 6 keys (incl. `'voice-input'` for the chat-panel mic path).
- Electron call-site renames at `useCommonMenuHandlers.ts:62`, `VoiceChatLauncher.tsx:31`, `pdf.tsx:434` — all three landed.
- Electron `useCommonMenuHandlers.ts:66` correctly keeps `'voice-input'` for the chat-panel mic path (per ARCH §2.4 the floating launcher gets `'voice-chat'`, the panel mic stays `'voice-input'`).
- `_layout.tsx` — `<PremiumFeatureSheet />` mounted in both E2E and normal branches, after `<RagExtractorHost />`.
- Test coverage — new `__tests__/PremiumFeatureDialog.test.tsx` reproduces the deleted co-located test's assertions on rendered title, description, bullets, "Maybe later" dismiss, "Sign in" → `openSignIn()`. Two minor assertions from the deleted file (`open={false}` renders nothing; `onOpenChange(false)` is also called on "Sign in") were dropped — acceptable, they're testing radix-ui's `Dialog`, not our code.
- Shared `should-gate.test.ts` + `feature-copy.test.ts` — both pass (10/10).
- Mobile `useRequireAuth.test.ts` + `PremiumFeatureSheet.test.tsx` — both pass (12/12 locally).
- Electron `features.test.ts` (rewritten) + `__tests__/PremiumFeatureDialog.test.tsx` — both pass (19/19 locally).
- All 5 implementation commits use Conventional Commit headers (`feat(scope)`, `refactor(scope)`).
- Mobile `tsc --noEmit` exits 0 (no new TS errors).

---

## Style / nits

1. `apps/mobile/components/auth/PremiumFeatureSheet.tsx:8` imports `useColorScheme` from `'react-native'`. The mobile codebase convention is `import { useColorScheme } from '@/hooks/use-color-scheme'` (see `app/_layout.tsx:17`, `components/parallax-scroll-view.tsx:11`). No functional difference today; the `@/hooks` wrapper exists for web parity.

2. `apps/mobile/components/auth/PremiumFeatureSheet.tsx:53` — `useRef<Text>(null)` is typed against the `Text` component, not its instance type. The cast on line 70 (`as unknown as { _nativeTag?: number }`) papers over this. Not wrong, but `useRef<View>(null)` would be the conventional ref type for a native node.

3. `apps/mobile/app/chat/[bookId].tsx:191-198` — `messageIndexById` is rebuilt on every render (no `useMemo`). Fine while message lists are <1000 items, but it's churn during typing. Out of Phase 1 scope; probably belongs to whichever commit added the testID indexing.

4. `apps/mobile/components/auth/PremiumFeatureSheet.tsx:67-74` — the `setTimeout(..., 350)` for `setAccessibilityFocus` will race the unmount path (close-while-opening). Cleanup clears the timer, so no leak, but consider whether the user notices a 350ms focus shift on the rapid-open-close case.

5. `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx:11` still imports `PremiumFeature` from `'./features'`. Since `features.ts` re-exports the type from shared, this works, but pinning directly to `'@rishi/shared/auth-gating'` would document the source of truth.

---

## Out of scope

- The `useFileSystem` adapter swap + `readerDefaultTheme` `useMemo` in `app/reader/[id].tsx` belong to a different Phase / fix; they ride along with commit `8a4e30fb`. Mentioned above as commit-hygiene drift, not as a Phase 1 finding.
- E2E testID renames (`chat-screen` → `screen-chat-detail`, etc.) and the new `messageIndexById` indexing are E2E test scaffolding, not Phase 1.
- `app/reader/[id].tsx:362-403` (`handleReadFromSelection`) — selection-driven `PLAY_FROM` is technically a TTS start path and should probably be gated too, but it's outside the listed 7. Bundle with Finding #2's fix when you touch the per-format readers anyway.
- AZW3 reader: per the parity spec the screen exists but I did not find a dedicated `app/reader/azw3/*` route — the MOBI reader appears to handle azw3 via shared chunker. Confirm before extending the gate fix.
- The `__tests__/components/auth/PremiumFeatureSheet.test.tsx`'s bottom-sheet mock renders children inline regardless of `index={-1}`, so the test "renders no visible feature copy when premiumGateOpen is false" is what forced the early-return-null in production code (GREEN.md deviation #1). Behaviour-equivalent in production; flagging only in case the deviation surprises future readers of the component.

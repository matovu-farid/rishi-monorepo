# Loop C — Final Integration Check

Date: 2026-05-21
Scope: Verify cross-domain wiring after Hunter-1 / Hunter-2 / Hunter-3 fix
batches land. Read-only audit; no app run.

---

## Per-flow verdicts

### Flow 1 — Sign-in → library → reader (full lifecycle) · **PASS**

Invariants:

1. Root `_layout.tsx` calls `hydrateAuth()` once at boot (single call site).
   `apps/mobile/app/_layout.tsx:52-56` ✓
2. `hydrateAuth` is async, reads MMKV + expo-secure-store, sets
   `authHydrated: true` in `finally`. `lib/stores/authStore.ts:98-141` ✓ (H1-04)
3. `(tabs)/_layout.tsx` guards on `authHydrated` then on `isAuthenticated`,
   redirects to `/(auth)/sign-in` when no session. Lines 43-46 ✓
4. `(auth)/_layout.tsx` no longer reads secure-store itself — defers entirely
   to the store, eliminating the dual-effect race. Lines 1-19 ✓ (H1-04 follow-on)
5. Library → reader navigation routes by `book.format`. `(tabs)/index.tsx:85-98` ✓

### Flow 2 — Book import → indexing → AI chat (per format) · **PASS**

Invariants:

1. `handleIncomingFile` dedupes by URL while in-flight. `lib/file-handler.ts:111-127` ✓ (H1-02)
2. Picker-driven imports (`file-import.ts`) AND OS-share-sheet imports
   (`file-handler.ts`) both funnel through `createMobileBookImportService(...)`.
   `lib/file-import.ts:14,60`, `lib/file-handler.ts:17,159` ✓
3. `DbPort.saveBook` and `DbPort.updateBookCover` AND the default
   `CoverPort.updateBookCover` all call `triggerSyncOnWrite()`. 
   `book-import/adapters.ts:150, 202, 368` ✓ (H3-03)
4. `embedBook` (called by `EmbedPort.generateChunks`) skips chunks whose
   `embeddings[j]` is undefined. (H3-01 — confirmed by passing
   `__tests__/rag-pipeline.test.ts`)
5. EPUB chunker normalizes spine hrefs (`opfDir+href` → `normalizeZipPath`),
   accepts absolute hrefs (`href.startsWith('/')`), and tolerates manifest
   `href` BEFORE `id`. `lib/rag/chunker.ts:141-145, 296+` ✓ (H3-02/05/07)
6. EPUB cover extractor matches `id`-with-`cover` heuristic in either
   attribute order, and resolves `../` segments.
   `packages/shared/src/formats/epub-cover.ts:48, 155-157` ✓ (H3-04/06)
7. PDF/DJVU readers reach `RagExtractorHost` (mounted at root layout) via
   the WebView rag-port bridge. `app/_layout.tsx:104, 119` ✓

### Flow 3 — TTS playback ↔ voice-chat interruption ↔ resume · **PASS**

Invariants:

1. All four readers (`[id]`, `pdf/[id]`, `mobi/[id]`, `djvu/[id]`) import
   `useTtsChatBridge` AND call it with `realtimeStatus`. Verified by
   `grep -rn useTtsChatBridge` (4 production call sites). ✓
2. `useTtsChatBridge` dispatches `CHAT_STARTED` for
   `connecting|active|speaking`, `CHAT_ENDED` otherwise — debounced via
   `lastDispatched.current`. `hooks/useTtsChatBridge.ts:33-50` ✓
3. Shared `playerMachine` preserves `paragraphIndex` across CHAT_STARTED →
   CHAT_ENDED (`wantsAutoResumeAfterChat=true`). 
   `packages/shared/src/machines/playerMachine.ts:37-44, 212-221` ✓
4. `useVoiceChat.stop()` → `svc.deactivate()` → shared service's
   `disposeInternal()` calls `session.close()`. `service.ts:128` ✓
5. `RealtimeSession.close()` stops every cloned track on
   `transport.sendStream` BEFORE closing the peer connection.
   `lib/voice-chat/realtime-session.ts:343-378` ✓ (H2-01)

### Flow 4 — Highlight CRUD with sync · **PASS**

Invariants:

1. `insertHighlight`, `updateHighlight`, `deleteHighlight`, `restoreHighlight`
   AND `insertPdfHighlight` all call `triggerSyncOnWrite()`.
   `lib/highlight-storage.ts:68, 113, 129, 151, 213` ✓
2. `triggerSyncOnWrite` debounces 2s and clears its timer on next call.
   `lib/sync/triggers.ts:48-56` ✓
3. Sync engine pushes dirty highlights (drizzle-adapter selects
   `isDirty=true`, marks pushed rows clean, applies LWW pull). 
   `lib/sync/drizzle-adapter.ts:52-53, 109-122, 155-157` ✓
4. Shared engine push-then-pull cycle wraps `markSyncInProgress` for
   crash-recovery. `lib/sync/engine.ts:36-50` ✓

### Flow 5 — Auth 401 mid-operation · **PASS**

Invariants:

1. `apiClient` on `response.status === 401` calls `signOut()` (wipes
   secure-store). `lib/api.ts:58-59` ✓
2. Then lazily-requires `useAuthStore` and calls `clearSession()` so the
   in-memory store flips `isAuthenticated:false`.
   `lib/api.ts:60-67` ✓ (H1-03)
3. `(tabs)/_layout.tsx` re-renders on `isAuthenticated` change and
   `<Redirect href="/(auth)/sign-in" />` fires. Lines 16, 45 ✓
4. Settings sign-out path (manual log-out) is safe: `try/catch/finally`
   around `signOut()` + `clearSession()`.
   `app/(tabs)/settings/index.tsx:64-80` ✓ (H1-01)

### Flow 6 — File association (OS Open With) · **PASS**

Invariants:

1. Root layout subscribes to BOTH `Linking.getInitialURL()` AND
   `Linking.addEventListener('url', …)`. Both call `handleIncomingFile`
   when `isFileUrl(url)` is true. `app/_layout.tsx:64-94` ✓
2. `isFileUrl` rejects `rishimobile://` (auth deep-links) and matches
   `file://` / `content://`. `lib/file-handler.ts:58-62` ✓
3. Dedup set in `handleIncomingFile` swallows the second call (cold-start
   race) so the user sees one book row, not two.
   `lib/file-handler.ts:30-35, 111-127` ✓ (H1-02)
4. Import then triggers fire-and-forget `indexBook` which writes chunks
   AND calls `triggerSyncOnWrite()` via the cover/save ports.
   `lib/file-handler.ts:181-190` + adapters above ✓ (H3-03)

### Flow 7 — Onboarding tour resumes after cold-start · **SUSPECT (by design)**

Invariants:

1. `tourCompleted` IS persisted to MMKV under `tour-completed`. 
   `tutorialStore.ts:88-98, 103` ✓
2. `tourStep`, `tourActive`, `tourPaused` are NOT persisted. After
   cold-start the store always rehydrates with `tourStep: 0` and
   `tourActive: false`. `tutorialStore.ts:100-105` — **by design, mirrors
   electron**.
3. `(tabs)/_layout.tsx` re-fires `startTour()` after sign-in IF
   `!tourCompleted`. Lines 32-41 ✓ — but this starts the tour at step 0,
   not at the mid-step the user left.
4. Documented in `__tests__/onboarding/tour-resume.test.ts:8-14` ("tourStep
   is NOT persisted: starts at 0 on cold-start even after advancing the
   tour") — this is the asserted contract, not a defect.

**Verdict: the flow as written in the prompt ("tour continues from same
step") DOES NOT hold; the actual behaviour is "tour restarts at step 0 on
cold-start". This matches electron parity by design.** No new bug; flagged
because the spec text and the code disagree. Owner should clarify whether
mobile-parity requires the strict re-resume (would need persisting
`tourStep`) or whether the documented "restart at 0" contract is the goal.

---

## Newly-discovered cross-domain bugs

**None.** All Hunter fixes integrate cleanly:

- H1-04 → H1-03 do not collide: `hydrateAuth` is the only secure-store
  reader on cold-start; the 401 clear path calls `signOut()` then
  `clearSession()` which uses the store's own action, not a re-hydration.
- H1-02 dedup is keyed on the raw URL, so successive imports from
  different share-sheet sources (different `file://...Inbox/...` paths
  generated by iOS on each share) are still distinct imports.
- H3-03 fires `triggerSyncOnWrite` once per inserted row AND once per
  cover update. The 2s debounce in `triggers.ts:48-56` coalesces all of
  these into a single push, so importing 10 books in rapid succession
  results in one sync cycle, not eleven.
- H2-01 track-stop runs BEFORE `pc.close()`. Order is correct (WHATWG
  requires explicit `track.stop()` — closing the PC alone is not
  sufficient).
- H3-04 → H3-07 are all pure-function fixes inside chunker / cover
  extractor; they cannot regress any caller.

**One pre-existing observation (NOT a Loop C regression):**

`apps/mobile/lib/stores/chatStore.setChatVoicePort()` is exported and
unit-tested, but no production code ever calls it. The store's `port`
field is permanently the `noopPort`. The actual voice-chat session is
driven via the `useVoiceChat` hook, which bypasses chatStore entirely.
File: `lib/stores/chatStore.ts:75, 83`.

This is **electron parity** (same shape there) and **not a new bug**. The
practical impact is that `chatStore.voiceState` always reads `'idle'`. If
any UI ever starts reading `voiceState` from chatStore (instead of via
`useVoiceChat`), it will silently never update. Owner: future joint
refactor with electron's chatStore.

---

## Final test counts

| Surface | Result | Pre-existing failures |
| ------- | ------ | --------------------- |
| `packages/shared` (vitest) | **482 / 482 pass** | none |
| `apps/mobile` (jest) | **532 / 534 pass** | `__tests__/vector.test.ts` (1) and `__tests__/guardrails.test.ts` (1) — both documented as pre-existing baseline failures in Hunter-3-BUGS.md and Hunter-1-BUGS.md context; neither is touched by Loop C work |
| `workers/worker` (vitest) | **22 / 22 pass** | none |
| `apps/rishi-electron` (tsc) | **clean** | none |

Mobile breakdown: 72 suites passed, 2 failed (the two pre-existing ones
above). Loop C did not introduce a single new failing test.

---

## Verdict: **parity loop COMPLETE**

Justification:

- All 13 fixes (H1-01..04, H2-01..02, H3-01..07) are integrated and
  reachable from the relevant entry points.
- Every flow except Flow 7 passes its invariants; Flow 7 is SUSPECT only
  because the prompt's wording diverges from the documented "tour
  restarts at 0 after cold-start" contract — which is electron parity by
  design and tested as such. Not a bug, possibly a spec clarification.
- No new cross-domain regressions found.
- Test totals match the baseline (only the two known pre-existing
  failures remain; everything Hunters added is green).
- `apps/rishi-electron` typecheck remains clean — no shared-package
  changes (H3-04/06 in `packages/shared/src/formats/epub-cover.ts`)
  broke electron's consumers.

Recommended follow-ups (out-of-scope for Loop C):

1. Spec/contract reconciliation for Flow 7. Decide whether mobile should
   persist `tourStep` (deviates from electron) or whether docs should be
   updated to state that the tour restarts on cold-start.
2. `chatStore.setChatVoicePort` cleanup — either install the port at app
   boot or delete the dead surface.
3. Joint refactor for "OPF / zip path is more permissive than the parser
   assumes" — H3-02/05/06/07 all hit the same class of issue; a single
   shared helper (`parseManifestItems`, `resolveOpfPath`) would prevent
   future drift.

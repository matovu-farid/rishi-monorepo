# Coverage Audit — Mobile Parity (Loop B kickoff)

**Date:** 2026-05-21
**Auditor:** test-coverage sweep against the 11-batch parity effort
**Scope:** `apps/mobile` + `packages/shared` (not `apps/rishi-electron` — read-only)

This audit was produced by:
1. Reading all 11 batch notes + GAP-ANALYSIS.md + VERIFICATION.md
2. Enumerating the 53 mobile + 34 shared test files
3. Cross-referencing every feature implementation against the test surface
4. Spot-checking 20+ source/test pairs for behavior, error path, and integration depth

Reference: tests currently pass at 432/434 mobile jest (2 pre-existing baseline failures), 480/480 shared, 22/22 worker. Adding coverage should not break that ratio.

---

## 1. Coverage summary table

Legend: **Y**=covered well, **P**=partial, **N**=no test. "Integration" = wire-up between modules (not just unit-level coverage).

| Feature                              | Behavior | Error path | Edge case | Integration |
| ------------------------------------ | -------- | ---------- | --------- | ----------- |
| Auth (Better-Auth deep-link, PKCE)   | Y        | P          | P         | P           |
| Sync engine + adapter                | Y        | P          | P         | Y           |
| Sync status listener                 | Y        | N          | P         | P           |
| File-sync (R2 upload/download)       | N        | N          | N         | P           |
| Connectivity machine + port          | Y        | P          | Y         | P           |
| RAG chunker (EPUB)                   | P        | P          | P         | P           |
| RAG chunker (PDF)                    | Y        | P          | Y         | P           |
| RAG chunker (MOBI/AZW3)              | Y        | P          | P         | P           |
| RAG chunker (DJVU)                   | Y        | P          | P         | P           |
| RAG embedder (on-device + fallback)  | P        | P          | N         | P           |
| RAG pipeline (embedBook orchestration)| P       | P          | N         | P           |
| Book import (picker)                 | Y        | Y          | P         | Y           |
| Book import (URL)                    | N        | N          | N         | N           |
| Book import (file-handler / OpenWith)| Y        | Y          | P         | Y           |
| File-handler (Android content://)    | P        | P          | N         | P           |
| EPUB reader screen                   | N        | N          | N         | P           |
| EPUB highlights (insert/update/delete/restore) | P | N      | P         | P           |
| EPUB bookmarks                       | Y        | N          | Y         | P           |
| EPUB search panel                    | Y        | N          | Y         | N           |
| EPUB read-from-selection (G17)       | Y        | Y          | P         | P           |
| PDF reader (WebView bridge)          | Y        | Y          | Y         | P           |
| PDF highlights                       | Y        | P          | P         | P           |
| PDF outline / TOC                    | Y        | P          | Y         | N           |
| PDF go-to-page (iOS + Android)       | Y        | Y          | Y         | P           |
| PDF read-from-selection              | Y        | P          | P         | P           |
| MOBI reader                          | N        | N          | N         | P           |
| DJVU reader                          | N        | N          | N         | P           |
| TTS service (queue, cache, cancel)   | Y        | Y          | Y         | Y           |
| TTS chat-bridge (CHAT_STARTED/ENDED) | Y        | N          | Y         | Y           |
| TTS reconcile (active paragraph)     | Y        | N          | Y         | Y           |
| TTS visual-cue classify              | Y        | N          | Y         | Y           |
| TTS visual-cue render gate           | Y        | N          | P         | P           |
| TTS seed-paragraphs                  | N        | N          | N         | P           |
| Voice-chat service (mobile)          | P        | P          | P         | Y           |
| Voice-chat realtime-session (mobile) | P        | N          | N         | P           |
| Voice-chat page-capture              | Y        | P          | Y         | Y           |
| Voice-chat rag-port (mobile)         | N        | N          | N         | P           |
| Voice-chat sounds (chime, no-ops)    | N        | N          | N         | N           |
| Voice-chat media-port                | P        | N          | N         | P           |
| Onboarding tutorial (tour + registry)| Y        | N          | Y         | Y           |
| Settings screen                      | Y        | N          | P         | P           |
| File association (iOS/Android open-with) | Y    | Y          | P         | Y           |
| Stores: prefs/player/pdf/chat/auth/tutorial | Y | N         | P         | Y           |
| MMKV storage adapter                 | Y        | Y          | Y         | Y           |
| Source-reference / citations         | Y        | N          | Y         | Y           |
| Dev-bypass header (N01)              | Y        | Y          | Y         | P           |
| Cover extraction (EPUB)              | Y        | Y          | Y         | P           |
| Cover extraction (MOBI/AZW3)         | Y        | Y          | Y         | P           |
| Conversation storage                 | Y        | N          | P         | Y           |

---

## 2. Prioritized gap list (40 items)

### P0 — functional bug risk

| ID    | Feature                   | What's missing                                                                                                       | Severity | Suggested test file                                                       | Suggested test name                                                                  | Effort |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------ |
| CG01  | Auth                      | `lib/auth.ts:69-73` rejects callback state-mismatch (replay protection). No test covers that branch.                 | P0       | `__tests__/auth/auth-flow.test.ts`                                        | `signIn rejects callback whose state differs from /mobile/start state`               | S      |
| CG02  | Sync engine               | `sync` push 401/403 from worker — does engine surface, retry, or silently swallow? No test exercises non-2xx.        | P0       | `__tests__/sync.test.ts`                                                  | `sync surfaces error and leaves dirty flags untouched on 401 from /api/sync/push`    | S      |
| CG03  | File-sync upload          | `uploadBookFile` R2 PUT failure path (non-ok response). Currently `lib/sync/file-sync.ts` has zero direct tests.     | P0       | `__tests__/sync/file-sync.test.ts` (new)                                  | `uploadBookFile throws when presigned URL PUT returns 5xx`                           | M      |
| CG04  | File-sync download        | `downloadBookFile` atomic move + DB filePath update — failure leaves no orphan tmp + does NOT update DB.             | P0       | `__tests__/sync/file-sync.test.ts` (new)                                  | `downloadBookFile rolls back tmp file and does not write filePath when move fails`   | M      |
| CG05  | URL import                | `importBookFromUrl` invalid URL, HEAD failure, download non-ok, unrecognized content-type — all untested.            | P0       | `__tests__/book-import/url-import.test.ts` (new)                          | `importBookFromUrl throws on 404`, `…falls back to content-type sniff when HEAD fails` | M    |
| CG06  | Voice-chat realtime       | Tool-dispatch error path: `handleToolCall` catches in `realtime-session.ts:237` but no test asserts `'error'` emit.  | P0       | `__tests__/voice-chat/realtime-session.test.ts` (new)                     | `bookContext tool emits error event and replies with error payload on RAG throw`     | M      |
| CG07  | Voice-chat realtime       | SDP-exchange failure: `realtime-session.ts:311` throws on non-200, no test for it.                                   | P0       | `__tests__/voice-chat/realtime-session.test.ts` (new)                     | `connect() throws on non-200 SDP response and never sets remote description`         | S      |
| CG08  | RAG embedder              | On-device embedder unready → server fallback path. `embedTextsOnServer` failure scenario untested.                   | P0       | `__tests__/rag/embedder-fallback.test.ts` (new)                           | `pipeline embeds chunks via server when on-device model is unready and worker 200s`  | S      |

### P1 — behavior gap

| ID    | Feature                   | What's missing                                                                                                       | Severity | Suggested test file                                                       | Suggested test name                                                                  | Effort |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------ |
| CG09  | Auth                      | `signIn` POST `/mobile/start` non-200 (network error, 500) — caller never reaches the browser open.                  | P1       | `__tests__/auth/auth-flow.test.ts`                                        | `signIn rejects when /mobile/start returns 500 and does not open browser`            | S      |
| CG10  | Auth                      | `signIn` while already signed-in — does it clobber or reject? No test.                                               | P1       | `__tests__/auth/auth-flow.test.ts`                                        | `signIn overwrites existing bearer when called again (or rejects — pin behavior)`    | S      |
| CG11  | Highlight storage (EPUB)  | `insertHighlight`/`getHighlightsByBookId`/`updateHighlight`/`deleteHighlight` only tested via PDF path. EPUB row CRUD has no direct test. | P1 | `__tests__/highlights/epub-storage.test.ts` (new) | `insertHighlight stores epubcfi row and survives roundtrip`                          | S      |
| CG12  | Highlight storage         | `triggerSyncOnWrite` is asserted in `conversation.test.ts` but NOT verified for `insertHighlight`/`deletePdfHighlight`/`restoreHighlight`. | P1 | `__tests__/pdf/highlights.test.ts` | `insertPdfHighlight calls triggerSyncOnWrite exactly once`                            | S      |
| CG13  | TTS                       | TTS service `requestAudio` 4xx/5xx from worker — recorded as auth-error path only. HTTP audio fetch failure untested. | P1     | `__tests__/tts/tts-service.test.ts`                                       | `requestAudio rejects and emits onError when audio worker returns 500`                | S      |
| CG14  | Voice-chat                | Mic permission denied (Android `PermissionsAndroid.request` rejected) — no test.                                     | P1       | `__tests__/voice-chat/service.test.ts`                                    | `activate rejects with permission error when getUserMedia throws PermissionDenied`    | S      |
| CG15  | Voice-chat                | Ephemeral key mint fails (`apiClient` 401). Today the test stubs `client_secret` 200 — failure branch unexercised.   | P1       | `__tests__/voice-chat/service.test.ts`                                    | `activate transitions to error when ephemeral key mint returns 401`                   | S      |
| CG16  | Page capture              | `captureRef` throws (WebView unmounted mid-capture). Code in `page-capture.ts` has no try/catch — test should assert promise rejects cleanly. | P1 | `__tests__/voice-chat/page-capture.test.ts` | `captureCurrentPage propagates captureRef errors instead of returning a corrupt blob` | S      |
| CG17  | RAG chunker (EPUB)        | Corrupt EPUB (missing `META-INF/container.xml`, missing OPF) — chunker logs warns + returns []. Behavior untested.   | P1       | `__tests__/rag/chunker-epub.test.ts` (new)                                | `getChunks returns [] for an EPUB whose container.xml is missing`                    | S      |
| CG18  | RAG pipeline              | `pipeline.embedBook` with no chunks (empty book) — does it write a sentinel or just exit?                            | P1       | `__tests__/rag-pipeline.test.ts`                                          | `embedBook is a no-op when chunker returns no paragraphs`                            | S      |
| CG19  | Onboarding                | Tour resumes from persisted MMKV state across cold-start (tutorialStore persist + initial activation flow).           | P1       | `__tests__/onboarding/tour-resume.test.ts` (new)                          | `tour resumes at the saved tourStep after store rehydrates from MMKV`                | S      |
| CG20  | Settings                  | "Sign out" branch fails (`signOut` throws) — UI doesn't surface or rolls back? No test.                              | P1       | `__tests__/settings/settings.test.tsx`                                    | `Sign out button shows error and keeps user signed-in when lib/auth.signOut throws`   | S      |
| CG21  | EPUB read-from-selection  | Selection that spans two paragraphs — partial-first should be only the suffix of paragraph A; resolver behavior?      | P1       | `__tests__/tts/epub-read-from-selection.test.tsx`                         | `resolver picks first paragraph and trims partialFirst to selection start for cross-paragraph selections` | S |
| CG22  | PDF reader                | Highlight tap → popover open: `PdfWebReader` `highlightTapped` outgoing event has no test asserting the screen dispatches the picker. | P1 | `__tests__/pdf/pdf-reader-highlight-tap.test.tsx` (new) | `tapping a highlighted region opens the recolor/delete picker via the bridge`         | M      |

### P2 — edge case

| ID    | Feature                   | What's missing                                                                                                       | Severity | Suggested test file                                                       | Suggested test name                                                                  | Effort |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------ |
| CG23  | File-handler              | Android `content://` with no extension hint — `detectFormatFromUrl` returns null (untested case).                    | P2       | `__tests__/file-handler.test.ts`                                          | `detectFormatFromUrl returns null for content:// with no extension and caller surfaces unsupported reason` | S |
| CG24  | File-handler              | iOS file URI with spaces + non-ASCII (`.epub` doesn't decode without `decodeURIComponent`).                          | P2       | `__tests__/file-handler.test.ts`                                          | `handleIncomingFile decodes %20 and unicode in titleFromUrl`                          | S      |
| CG25  | TTS reconcile             | All-empty `currentParagraphs` mid-prefetch — should not crash + no event emitted.                                    | P2       | `__tests__/tts/reconcile.test.ts`                                         | `reconcileTtsHighlight stays at -1 across rapid currentParagraphs swaps`              | S      |
| CG26  | Bookmarks                 | toggleBookmark with two equivalent CFIs in DIFFERENT spines (no prefix match) → should create new, not delete.       | P2       | `__tests__/bookmarks/bookmark-storage.test.ts`                            | `toggleBookmark creates fresh row when no spine-prefix match exists`                  | S      |
| CG27  | Search panel              | Search returning zero matches across all spine items — empty state UX.                                                | P2       | `__tests__/search/search-panel.test.tsx`                                  | `SearchPanel shows empty state when no spine yields a match`                          | S      |
| CG28  | Voice-chat machine        | `interrupt()` while the data channel is open — confirms `response.cancel` is sent.                                   | P2       | `__tests__/voice-chat/realtime-session.test.ts` (new)                     | `interrupt() sends response.cancel exactly once`                                      | S      |
| CG29  | Voice-chat agent          | `updateAgent` post-session change of language — `session.update` re-sent with new instructions.                      | P2       | `__tests__/voice-chat/realtime-session.test.ts` (new)                     | `updateAgent emits session.update with new instructions text`                         | S      |
| CG30  | Auth (worker)             | Mobile `/mobile/start` rate-limit / 429 path — does Better-Auth retry?                                                | P2       | `workers/worker/src/routes/mobile.test.ts` (extend)                       | `mobile/start returns Retry-After header on rate-limit`                               | M      |
| CG31  | Onboarding registry       | Concurrent registers of the same target by 2 mounted screens — last-write-wins, but listener fires twice?            | P2       | `__tests__/onboarding/tour-state.test.ts`                                 | `subscribeTourTargets fires once per register call, not coalesced`                    | S      |
| CG32  | Connectivity              | Mobile machine in `offline` → comes back online → sync trigger fires. Wire-up between machine and trigger untested.   | P2       | `__tests__/connectivity/online-trigger-sync.test.ts` (new)                | `connectivity transitions offline→online and triggers sync within debounce window`    | M      |

### P3 — nice-to-have

| ID    | Feature                   | What's missing                                                                                                       | Severity | Suggested test file                                                       | Suggested test name                                                                  | Effort |
| ----- | ------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------ |
| CG33  | Voice-chat sounds         | `playReadyChime` writes the chime WAV once, then re-uses it (idempotency + dedup of WAV write).                      | P3       | `__tests__/voice-chat/sounds.test.ts` (new)                               | `playReadyChime writes chime.wav once and re-plays from cache`                        | S      |
| CG34  | RAG chunker (MOBI)        | EXTH-less MOBI (rare) — does fallback HTML chapter path produce text?                                                | P3       | `__tests__/rag/chunker-mobi.test.ts`                                      | `getChunks falls through to chapter-html stripping when paragraph splitter is empty`  | S      |
| CG35  | Settings                  | Voice language change actually flips `prefsStore.voiceLanguage` and persists.                                        | P3       | `__tests__/settings/settings.test.tsx`                                    | `changing voice language persists to MMKV and survives store rehydrate`               | S      |
| CG36  | TTS visual-cue            | LaTeX delimiter on paragraph boundary — `$x$ continued` mid-sentence.                                                | P3       | `__tests__/tts/visual-cue-classify.test.ts`                               | `classifies inline LaTeX surrounded by prose as equation`                             | S      |
| CG37  | PDF go-to-page            | Validation: negative, zero, decimal, overflow page numbers — `goto-page-validate.ts` likely has the logic but the Android UI flow is only smoke-tested. | P3 | `__tests__/pdf/goto-page.test.ts`         | `validate rejects 0 and numbers > totalPages with a localized message`                | S      |
| CG38  | EPUB highlight undo       | Snackbar dismiss → action no longer firable (timer cleared).                                                          | P3       | `__tests__/highlights/undo-snackbar.test.tsx`                             | `pressing Undo after auto-dismiss does NOT call restore (timer cleared)`              | S      |
| CG39  | Stores                    | `pdfStore.resetParagraphState` while a TTS PLAY is in-flight — ensures no leaked events post-reset.                  | P3       | `__tests__/stores/pdfStore.test.ts`                                       | `resetParagraphState mid-play clears activeParagraph and player state simultaneously` | S      |
| CG40  | Voice-chat                | Inactivity timeout fires (3 min) → service deactivates with reason. Mocking the clock today only covers connect timeout. | P3   | `__tests__/voice-chat/service.test.ts`                                    | `inactivity timer fires after 3 min idle and emits endedByAgent reason="inactivity"`  | M      |

---

## 3. High-risk files (modified by 3+ batches)

These files are at higher regression risk because multiple batches touched them; the current test coverage is mostly indirect.

| File                                       | Batches modified | Direct tests today                                          | Recommended additions                                                                 |
| ------------------------------------------ | ---------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `apps/mobile/app/_layout.tsx`              | 2B, 4, 5, 6, 7, 8 | None (RagExtractorHost mount + Linking listener untested) | Smoke: registers RAG extractors at mount; `Linking.addEventListener('url', …)` routes file URLs to handleIncomingFile and ignores `rishimobile://`. |
| `apps/mobile/app/(tabs)/_layout.tsx`       | 6, 8            | None (TourProvider mount + tab routing)                     | Smoke: TourProvider rendered once per tab navigator; settings tab visible.            |
| `apps/mobile/app/reader/[id].tsx` (EPUB)   | 7, 8 (G14, G15, G17, G10) | Source-grep tests for `useTtsChatBridge` only      | Add: tap-highlight opens popover; "Read from here" selection menu invokes resolver; undo snackbar wired to delete; visual-cue mounted. |
| `apps/mobile/app/reader/pdf/[id].tsx`      | 5, 7, 8         | Source-grep for TTS bridge + page-capture refs              | Add: outline tap navigates page; thumbnail modal opens; goto-page modal submits.      |
| `apps/mobile/app/reader/mobi/[id].tsx`     | 7, 8 (G14, G15) | Source-grep tests only                                      | Add: reader screen mounts, seeds paragraphs from chunks, dispatches PLAY.             |
| `apps/mobile/app/reader/djvu/[id].tsx`     | 7, 8 (G14, G15) | Source-grep tests only                                      | Add: same as MOBI.                                                                    |
| `apps/mobile/lib/voice-chat/realtime-session.ts` | 4         | No direct test (covered indirectly via shared service tests) | Add full unit test file: tool dispatch (3 tools × success/failure), SDP exchange, mute, interrupt, updateAgent. |
| `apps/mobile/lib/book-import/adapters.ts`  | 2B, 7, 8 (N08)  | Indirect via `file-import.test.ts` + `file-handler.test.ts` | Direct unit tests on CoverPort EPUB/MOBI/AZW3 branching + EmbedPort fallback chain.   |
| `apps/mobile/lib/rag/chunker.ts`           | 2A, 2B          | Per-format tests, no EPUB-corrupt coverage                  | EPUB malformed branches (CG17).                                                       |
| `apps/mobile/lib/sync/file-sync.ts`        | 1B, 4 (indirect) | Zero direct tests — only mocked from file-import tests     | Full unit file: hash, upload happy/dedup/failure, download atomic move + DB update.   |
| `apps/mobile/lib/auth.ts`                  | 1C, 8 (N01)     | `auth-flow.test.ts` (good)                                  | State-mismatch (CG01), /mobile/start failure (CG09), re-signIn (CG10).               |
| `apps/mobile/lib/api.ts`                   | 1C, 8 (N01)     | `api/dev-bypass.test.ts`                                    | `apiClient` 401 → calls `signOut()` (or doesn't); retry behavior on 5xx (if any).     |

---

## 4. Quick wins (10 high-value, low-effort tests to add first)

These are the highest-value items the next test-fill batch should ship. All are size-S and exercise a single observable behavior with minimal mocking churn.

1. **CG01** — auth state-mismatch rejection. One-liner addition to `auth-flow.test.ts`. Closes a security-sensitive replay-protection branch.
2. **CG02** — sync push 401 surfaces error. Tiny extension to `sync.test.ts`. Confirms the engine doesn't silently swallow auth failures.
3. **CG09** — `/mobile/start` non-200 in `signIn`. Mirrors CG01; uses the same `auth-flow.test.ts` plumbing.
4. **CG13** — TTS audio-worker 500 path. Extends existing `tts-service.test.ts` with a non-2xx fetch response — already-built mocks cover it.
5. **CG12** — assert `triggerSyncOnWrite` called by `insertPdfHighlight` / `deletePdfHighlight` / `restoreHighlight`. One assertion per existing test in `pdf/highlights.test.ts`.
6. **CG11** — EPUB highlight CRUD (new `highlights/epub-storage.test.ts`). Copy-paste the PDF highlight test pattern and swap to epubcfi.
7. **CG25** — TTS reconcile under empty `currentParagraphs` race. One-liner in `reconcile.test.ts`.
8. **CG36** — visual-cue classifier on inline LaTeX surrounded by prose. Extends `visual-cue-classify.test.ts` with one fixture.
9. **CG34** — MOBI EXTH-less fallback path. Extends `chunker-mobi.test.ts` with a fixture whose paragraph-splitter yields nothing.
10. **CG16** — page-capture propagates captureRef errors. Extends existing `page-capture.test.ts` by making the mock reject.

These ten can land in a single half-day commit. They close the loudest functional / security gaps without requiring new test infrastructure.

---

## 5. Recommended ordering for the test-fill batch

**Phase A — Quick wins (half day):** CG01, CG02, CG09, CG11, CG12, CG13, CG16, CG25, CG34, CG36. All extend existing test files; no new mock infrastructure.

**Phase B — File-sync (half day):** CG03, CG04. New `__tests__/sync/file-sync.test.ts`. Mock `apiClient` + `fetch` for the R2 PUT/GET; reuse the file-import mock for `expo-file-system`.

**Phase C — Voice-chat realtime-session (1 day):** CG06, CG07, CG28, CG29 + the `realtime-session.test.ts` file as a new home. Need to mock the WebRTC factory + data channel events. Pattern already established in `service.test.ts`.

**Phase D — URL imports (half day):** CG05. New `__tests__/book-import/url-import.test.ts`. Mocks: global `fetch`, `expo-file-system`, the book-import service factory.

**Phase E — Long-tail edge cases (half day):** CG10, CG17, CG19, CG20, CG21, CG22, CG30, CG40 and the remaining P2/P3 items.

Total estimated effort: **3 days** to bring all 40 gaps to green. Phase A alone moves the audit from 47 partial cells to ~37 and closes every P0 that is actually testable with existing infrastructure (CG03, CG04, CG05, CG06, CG07, CG08 still need their own new test files, which is Phase B/C/D work).

---

## 6. What this audit explicitly does NOT cover

- **Electron source** (`apps/rishi-electron`) — read-only, out of scope.
- **Maestro E2E flows** (`apps/mobile/.maestro/` if present) — beyond unit/integration scope.
- **Worker tests** beyond cross-referencing — they were Loop A-verified at 22/22.
- **Performance / load** — RAG embedding throughput, TTS prefetch saturation, etc.
- **Native modules** (react-native-webrtc, react-native-mmkv, react-native-view-shot) — assumed correct; we mock at the JS boundary.

_End of audit. 40 gaps catalogued; Phase A ships first._

# Gap Analysis (2026-05-21)

## Summary

Mobile (Expo SDK 54 / RN 0.81) ships a thinner, EPUB-first reader against the same Cloudflare Worker backend that Electron uses. Most non-UI feature logic already exists in `apps/rishi-electron` as port-injected TypeScript and is ready to be COPIED into `packages/shared` so mobile can adopt it without rewriting. The biggest structural divergences are: (a) **auth** — mobile uses Clerk's in-app SDK while Electron uses Better-Auth Redis polling, and the user wants the same auth on both; (b) **format coverage** — mobile's RAG/TTS/realtime stack is silently EPUB-only because PDF / MOBI / DJVU chunkers return `[]`; (c) **state architecture** — mobile has zero Zustand stores and no XState machines, so all the player/voice-chat/connectivity FSMs need to be ported, not just shared; (d) **PDF reader parity** — mobile PDF lacks highlights, outline, text selection, TTS, and AI chat. Total parity gaps: **32** (P0: 5, P1: 14, P2: 8, P3: 5).

## Gap Inventory Table

| ID | Feature | Electron status | Mobile status | Severity | Effort | Shared | Notes |
|---|---|---|---|---|---|---|---|
| G01 | Auth: Better-Auth + Redis polling | Implemented | Clerk Expo SDK | **P0** | L | Partial | User wants "same auth" |
| G02 | Shared types (highlight, conversation, paragraph, languages) | renderer/types/* | Re-derived | **P0** | S | **Yes** | DONE in Batch 0 |
| G03 | Sync engine + status + debouncer + connectivity | Uses @rishi/shared/sync-engine | Duplicate impl in mobile/lib/sync/* | **P0** | M | **Yes** | Replace mobile's bespoke engine |
| G04 | RAG: PDF text extraction + chunking | services/indexing/* with pdfjs-dist | Missing — returns `[]` | **P0** | L | Partial | Without this PDF AI chat/TTS/voice are dead |
| G05 | RAG: MOBI/AZW3/DJVU text extraction | formats.ts PalmDOC + foliate-js | Missing | **P0** | L | **Yes** | PalmDOC parser portable |
| G06 | PDF highlights + annotations | usePdfHighlights, HighlightLayer | Missing | P1 | L | Partial | Needs RN PDF text selection layer |
| G07 | PDF outline / TOC | react-pdf <Outline> + IPC | Missing | P1 | M | No | Parse via pdfjs in WebView |
| G08 | PDF text selection / copy | usePdfTextSelection | Missing | P1 | L | Partial | Hardest — may need WebView fallback |
| G09 | PDF "go to page" + thumbnails + virtualized scroll | @tanstack/react-virtual | Partial (thumbnails) | P2 | S | No | Add page-prompt UI |
| G10 | EPUB highlights + notes + colors | Implemented full popover + undo | Implemented (parity-adjacent) | P2 | S | **Yes** | Move undo logic + color enum to shared |
| G11 | EPUB bookmarks | bookmark-storage.ts + BookmarksList | Missing | P1 | M | **Yes** | Schema additions + UI |
| G12 | EPUB search panel | SearchPanel UI | Partial (inline) | P2 | S | No | Extract to bottom sheet |
| G13 | TTS service (queue, cache, prefetch) | Full impl, XState playerMachine | Partial: lib/tts/*, EPUB-only | P1 | L | **Yes** | Port playerMachine + service core |
| G14 | TTS: chat-position preservation | playerMachine CHAT_STARTED/ENDED | Missing | P1 | M | **Yes** | Falls out of G13 |
| G15 | TTS: visual cue (equation/figure badge) | TTSVisualCue + prefsStore toggle | Missing | P3 | S | Partial | Wait until G13 |
| G16 | TTS in PDF/MOBI/AZW3/DJVU | Reconcilers per format | Missing (EPUB only) | P1 | L | **Yes** | Depends G04/G05/G13 |
| G17 | Read-aloud from selection | modules/read-aloud-from + hooks | Missing | P2 | M | **Yes** | Depends G13 + G08 |
| G18 | Voice-chat: FSM + activation + key cache | services/voice-chat/* | Partial: ad-hoc realtime session | P1 | L | **Yes** | Port machine + key-cache + activation |
| G19 | Voice-chat: local VAD | local-vad.ts (RMS-based) | Missing | P2 | M | Partial | Algorithm portable, Web Audio API not |
| G20 | Voice-chat: page-capture vision tool | pageCapture + inspectCurrentPage | Missing | P2 | M | Partial | react-native-view-shot |
| G21 | Voice-chat: realtime agent prompts | buildRealtimeAgent.ts INSTRUCTIONS_TEMPLATE | Divergent system prompt | P1 | S | **Yes** | Critical for behavioral parity |
| G22 | Voice-chat: ready chime + thinking sound | readyChime + thinkingSound | Missing | P3 | S | Partial | expo-audio |
| G23 | AI Chat (text): per-book panel + citations | ChatPanel + useChat | Implemented (parity-adjacent) | P2 | S | **Yes** | Align prompts via shared types |
| G24 | Zustand stores | 11 stores | **Zero stores** | P1 | L | **Yes** | Add zustand + MMKV |
| G25 | XState machines | 4 machines (player, nav, connectivity, pdfReader) | None | P1 | M | **Yes** | Add xstate, port machines |
| G26 | Book import service | importer/indexer/dispatch | Partial: file-import only | P1 | M | **Yes** | Add indexing on import |
| G27 | OS file association / Open With | open-file + files:getPending | Missing | P2 | M | No | app.json LSItemContentTypes + intent-filter |
| G28 | Onboarding tutorial | tutorialStore + TourProvider | Missing | P2 | M | Partial | react-native-copilot or Reanimated overlay |
| G29 | Settings screen | routes/settings + prefsStore | Missing entire screen | P1 | S | **Yes** | /settings route in expo-router |
| G30 | Page-curl gesture | pagecurl/ drawPageCurl | Missing | P3 | L | Partial | @shopify/react-native-skia |
| G31 | AI Chat orb (floating) | AIChatOrb + VoiceChatLauncher | Missing | P3 | M | No | Reanimated; backed by G18 |
| G32 | Cover-image extraction on import | jszip OPF metadata in formats.ts | Missing | P2 | S | **Yes** | Copy EPUB cover extraction |

## Auth Reconciliation

Both clients target Better-Auth + PKCE. Electron uses Redis polling (workaround for protocol handler complexity); mobile will use clean OS-level deep links via expo-web-browser + expo-linking. Worker stays source of truth.

Worker change required (small, additive):
- Add `/mobile/start` (POST, accepts `{ challenge, state, provider }`, returns `{ authUrl }`)
- Add `/mobile/start/complete` (GET, the OAuth provider returns here, then redirects to `rishimobile://auth/callback?token=<bearer>&state=<state>`)
- Add `rishimobile://` to `trustedOrigins` in `workers/worker/src/auth.ts`
- Mount route in `workers/worker/src/index.ts`
- Reuse same Better-Auth `auth.handler` machinery as `/desktop/*` for session issuance
- Backward-compat: electron's `/desktop/start` + `/desktop/poll` remain untouched

Mobile change:
- Remove @clerk/expo and ClerkProvider
- Add expo-web-browser `openAuthSessionAsync(authUrl, 'rishimobile://auth/callback')`
- Handle callback via expo-linking; extract token, store in expo-secure-store
- Replace mobile/lib/auth.ts dead /api/auth/exchange call (endpoint never existed in worker)

## Recommended Execution Order

- **Batch 0** ✅ DONE: Shared waves 1+2+3 (14 files copied)
- **Batch 1A**: Worker mobile auth endpoints
- **Batch 1B**: Mobile foundation (Zustand + XState + sync consolidation)
- **Batch 1C**: Mobile auth swap (depends on 1A + 1B)
- **Batch 2**: G04 + G05 + G26 + G32 — format coverage
- **Batch 3**: G13 + G14 + G16 + G15 — TTS
- **Batch 4**: G18 + G21 + G19 + G20 + G22 — voice chat
- **Batch 5**: G06 + G07 + G08 + G09 + G17 — PDF reader
- **Batch 6**: G11 + G10 + G12 + G23 + G27 + G28 + G29 + G30 + G31 — polish

## Stop Condition

Parity achieved when:
1. Auth: mobile uses same Better-Auth PKCE flow; no Clerk dep in mobile/package.json
2. Formats: PDF/MOBI/AZW3/DJVU import produces non-empty chunks; AI chat works on each
3. TTS: works on every format via playerMachine with chat-resume
4. Voice chat: mic works on every format, uses shared INSTRUCTIONS_TEMPLATE, resumes TTS
5. PDF reader: text selection + highlights + outline + go-to-page + read-aloud
6. Library: /settings screen; cover images extracted; EPUB bookmarks
7. Shared: waves 1–4 landed; mobile no longer duplicates highlight/conversation/sync engine
8. State: mobile uses Zustand for player/prefs/chat/auth + XState for player/connectivity
9. Tests green: pnpm -C apps/{rishi-electron,mobile} typecheck && test; Maestro flows pass
10. Excluded by design: auto-updater, native menu, multi-window, local-file protocol (platform-impossible)

Page curl (G30) and AI chat orb (G31) are explicitly **not blockers** — they may ship after parity.

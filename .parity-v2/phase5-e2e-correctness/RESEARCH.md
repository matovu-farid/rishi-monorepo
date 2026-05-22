# Phase 5 — End-to-End Correctness: RESEARCH.md

Date: 2026-05-22
Author: researcher agent

---

## 1. Voice Chat Status per Format

| Format | Mobile state | Electron parity | Blockers |
|--------|---|---|---|
| EPUB | Full: `useRealtimeChat` → `useVoiceChat` → shared service. `requireVoiceChat` gate via bottom-bar + launcher. `useTtsChatBridge` wired. | Full | None functional. Empty ActivationContext sent to agent. |
| PDF | Partial: voice chat via launcher only (gated). NO bottom-bar voice toggle (no `onRealtimePress`). `useTtsChatBridge` wired. | Full | Discoverability gap only. |
| MOBI | Same as PDF. | Full | Same. |
| DJVU | Same as PDF. | Full | Same. |
| AZW3 | Routes to EPUB reader. | Full (via EPUB) | AZW3 rendering in epubjs unverified. |

## 2. Reader Functionality Matrix

| Feature | EPUB | PDF | MOBI | DJVU | AZW3 |
|---------|------|-----|------|------|------|
| Open/render | Yes | Yes | Yes | Yes | Routed to EPUB (unverified) |
| TTS | Yes (gated) | Yes (gated) | Yes (gated) | Yes (gated) | Via EPUB |
| Voice chat | Yes (toolbar + launcher) | Launcher only | Launcher only | Launcher only | Via EPUB |
| AI chat (text) | Yes (gated) | **NO** | **NO** | **NO** | Via EPUB |
| Highlights | Yes | Yes (picker, no sheet) | No | No | Via EPUB |
| Bookmarks | Yes | No | No | No | Via EPUB |
| Search | Yes | No | No | No | Via EPUB |

Critical gaps on PDF/MOBI/DJVU: No AI chat text entry. Phase 3 deferred Highlights/Bookmarks/Search for these formats — also Phase 5+.

## 3. Ready Chime + Thinking Sound — ALREADY DONE

Both implemented in `apps/mobile/lib/voice-chat/sounds.ts` and wired into `service.ts:93` via `createMobileEffectsPort()`.

- `playReadyChime`: synthesizes WAV (C5→E5, matching electron) on first call, cached to `Paths.cache`, plays via `expo-audio`.
- `startThinkingSound`/`stopThinkingSound`: documented no-op (on-screen chatStatus label suffices).

**No Phase 5 work needed for audio cues.**

## 4. Audio Asset Locations

Zero bundled files. Electron uses Web Audio API. Mobile synthesizes WAV at runtime (~13KB cached).

## 5. Outstanding Bugs

### P0 — Blocks correctness
- **5-P0-A**: `handleReadFromSelection` on EPUB not gated by `requireTTS`. File: `apps/mobile/app/reader/[id].tsx:313-355`. Selection → "Read from here" bypasses sign-in gate.

### P1 — Important
- **5-P1-A**: No `onChatToggle` on PDF/MOBI/DJVU. Phase 5 design flow #4 fails.
- **5-P1-B**: No Highlights/Bookmarks/Search sheets on PDF/MOBI/DJVU (Phase 3 deferred — defer to Phase 6).
- **5-P1-C**: `ChatInput` clears text before premium gate fires (`components/ChatInput.tsx:42-44`).
- **5-P1-D**: AZW3 rendering unverified (`e2e/reader-azw3.test.ts:13-16` covers routing only).

### Phase 4 review carryover (CRITICAL)
- **5-P0-B**: MiniPlayer morph container hard-pins `<GlassDisk size={52}>` top-left. When expanded to 240-280pt pill, controls render on bare transparent pixels. No glass effect on the expanded pill. File: `apps/mobile/components/player/MiniPlayer.tsx:298-313`. Fix: move BlurView/border/tint onto the outer morphing Animated.View.

### P2 — Polish (defer to Phase 6)
- Voice chat context empty on mobile (semantic, not functional)
- thinkingSound is no-op
- PDF outline/thumbnails in legacy modal
- EPUB progress pill shows chapter not %
- MiniPlayer auto-collapse jest timer warning
- Legacy sheet `sheetRef`/`theme` API

## 6. Test Coverage Gaps

### No tests
- `lib/voice-chat/sounds.ts` — zero
- `lib/voice-chat/realtime-session.ts` — zero
- `hooks/useVoiceChat.ts` — zero
- `hooks/useRealtimeChat.ts` — zero

### E2E gaps
- No E2E for: TTS play→pause→resume, voice chat connect→speak→finish, AI chat send→citations, highlights create→list→jump, sign-out mid-action
- DJVU suite fully skipped (no fixture)

## 7. Phase 5 Recommended Scope

### Must fix (P0/P1)
- **F1**: Gate `handleReadFromSelection` in EPUB with `requireTTS`
- **F2**: Add `onChatToggle` to PDF/MOBI/DJVU (3 lines per file)
- **F3**: Fix `ChatInput` lost text on gate (move setText after onSend)
- **F4**: MiniPlayer pill glass fix (Phase 4 carryover — move BlurView to morphing container)

### Should add
- **T1**: Unit tests for `sounds.ts` (WAV synthesis correctness)
- **T2**: Unit tests for `useVoiceChat` (mapToRealtimeStatus)
- **T3**: Verify AZW3 manually OR add Maestro/Detox assertion

### Defer to Phase 6
- Highlights/Bookmarks/Search on PDF/MOBI/DJVU
- Empty ActivationContext
- thinkingSound audio
- PDF outline migration
- EPUB progress pill % label
- Legacy sheet API cleanup
- BlurView wiring in Toolbar.tsx
- GlobalMiniPlayer dynamic tab bar height
- Drag-to-reposition

## Phase 5 budget
6 files to modify, 2 tests to add, ~1 manual verification. Atomic commits per fix.

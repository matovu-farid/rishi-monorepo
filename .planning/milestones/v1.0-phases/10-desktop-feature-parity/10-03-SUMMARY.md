---
phase: 10-desktop-feature-parity
plan: 03
subsystem: ui
tags: [chat, rag, voice-input, mediarecorder, epub, embeddings, source-references]

# Dependency graph
requires:
  - phase: 10-desktop-feature-parity-01
    provides: embed-fallback.ts, sync-triggers.ts, conversation.ts types, chat_atoms.ts
  - phase: 08-desktop-sync
    provides: Kysely DB with conversations/messages tables, SQLite schema
  - phase: 06-on-device-rag-ai-conversations
    provides: RAG architecture, getContextForQuery, chunk_data table, vector search

provides:
  - useChat hook: text-based RAG chat with SQLite persistence and write-triggered sync
  - useVoiceInput hook: MediaRecorder-based voice capture with Worker STT transcription
  - ChatPanel component: right-side sheet with message history and empty state
  - ChatInput component: text + voice input with live recording duration display
  - ChatMessage component: role-aligned bubbles with source chunk chips
  - SourceChip component: clickable badge navigating reader to source passage
  - process_epub.ts updated to use embedWithFallback for server embedding fallback

affects: [11-mobile-feature-parity]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - MediaRecorder API for in-browser audio capture with MIME type detection
    - Optimistic UI: user message rendered immediately before LLM response arrives
    - Source chunk metadata retrieved via chunk_data table matching context text
    - SourceChip click navigates rendition via spine index from pageNumber

key-files:
  created:
    - apps/main/src/hooks/useChat.ts
    - apps/main/src/hooks/useVoiceInput.ts
    - apps/main/src/components/chat/ChatPanel.tsx
    - apps/main/src/components/chat/ChatInput.tsx
    - apps/main/src/components/chat/ChatMessage.tsx
    - apps/main/src/components/chat/SourceChip.tsx
  modified:
    - apps/main/src/modules/process_epub.ts
    - apps/main/src/components/epub.tsx

key-decisions:
  - "MediaRecorder MIME type: check audio/webm;codecs=opus support first, fall back to audio/webm"
  - "Source chunks retrieved by matching context text against chunk_data.data column (exact match)"
  - "rendition?.display(pageNumber) used for source chip navigation (spine index)"
  - "Optimistic user message added to state before LLM call completes"
  - "Conversation auto-created on first use per book (no explicit 'New Chat' required)"

patterns-established:
  - "ChatPanel as shadcn Sheet (side=right, 440px) for non-blocking reader overlay"
  - "useChat(bookId, bookSyncId) pattern mirrors mobile useChat hook interface"

requirements-completed:
  - PARITY-D04
  - PARITY-D06

# Metrics
duration: 35min
completed: 2026-04-06
---

# Phase 10 Plan 03: Desktop Chat Panel and Voice Input Summary

**RAG-powered text chat panel with voice input and source reference chips wired into the desktop EPUB reader toolbar**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-04-06
- **Completed:** 2026-04-06
- **Tasks:** 3 (2 auto + 1 human-verify checkpoint)
- **Files modified:** 8

## Accomplishments

- Built `useChat` hook managing full RAG conversation loop: load/create conversation, optimistic user message, RAG retrieval via `getContextForQuery`, source chunk lookup in `chunk_data`, LLM call to Worker, persist assistant message with source_chunks JSON, trigger sync
- Built `useVoiceInput` hook using MediaRecorder API for in-browser audio capture with MIME type detection and Worker STT transcription via `/api/audio/transcribe`
- Created ChatPanel (shadcn Sheet, 440px right), ChatMessage (role-aligned bubbles), ChatInput (text + voice), and SourceChip (Badge with Tooltip) wired into epub.tsx toolbar with MessageSquare icon
- Updated `process_epub.ts` to replace direct `embed()` call with `embedWithFallback()` for server-side fallback when on-device embedding is unavailable

## Task Commits

1. **Task 1: Create useChat hook, useVoiceInput hook, and update process_epub.ts** - `2306f7c` (feat)
2. **Task 2: Create ChatPanel, ChatInput, ChatMessage, SourceChip and wire into epub.tsx** - `1a4f43c` (feat)
3. **Task 3: Human verification checkpoint** - approved by user

## Files Created/Modified

- `apps/main/src/hooks/useChat.ts` - Text-based RAG chat hook with SQLite persistence and write-triggered sync
- `apps/main/src/hooks/useVoiceInput.ts` - MediaRecorder voice capture + Worker STT transcription
- `apps/main/src/components/chat/ChatPanel.tsx` - Sheet panel with message list, empty state, error state, auto-scroll
- `apps/main/src/components/chat/ChatInput.tsx` - Single-line input with voice button (Mic) and send button (SendHorizontal)
- `apps/main/src/components/chat/ChatMessage.tsx` - Role-aligned message bubbles with loading pulse animation
- `apps/main/src/components/chat/SourceChip.tsx` - Badge with Tooltip showing page/chapter reference, navigates reader on click
- `apps/main/src/modules/process_epub.ts` - Replaced `embed()` with `embedWithFallback()` for server fallback
- `apps/main/src/components/epub.tsx` - Added MessageSquare toolbar button and ChatPanel render

## Decisions Made

- MediaRecorder MIME type negotiation: prefer `audio/webm;codecs=opus`, fall back to `audio/webm` based on `isTypeSupported()` check
- Source chunks retrieved by exact-matching context text strings against `chunk_data.data` column — avoids needing a second vector search
- `rendition?.display(pageNumber)` used for source chip navigation, treating pageNumber as spine index (simple MVP approach)
- Conversation auto-created on first chat open per book — no explicit "New Chat" button required
- Optimistic UI: user message added to local state immediately, loading bubble shown, then replaced with assistant response

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Desktop chat feature parity with mobile is complete (PARITY-D04, PARITY-D06)
- Phase 10 is fully complete — all 3 plans delivered
- Phase 11 (Mobile Feature Parity) can begin: realtime voice chat, AI guardrails, sync status indicator, Sentry

---
*Phase: 10-desktop-feature-parity*
*Completed: 2026-04-06*

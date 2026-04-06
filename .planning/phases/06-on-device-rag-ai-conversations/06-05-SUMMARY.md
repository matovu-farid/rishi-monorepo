---
phase: 06-on-device-rag-ai-conversations
plan: 05
subsystem: ui
tags: [react-native, expo-router, rag, chat, vector-search, llm, nativewind]

# Dependency graph
requires:
  - phase: 06-on-device-rag-ai-conversations (plans 01-04)
    provides: sqlite-vec vector store, conversation CRUD, embedding pipeline, server embedding fallback
provides:
  - RAG query hook wiring embed -> vector search -> LLM completion
  - Chat tab with conversations list screen
  - Per-book chat screen with message bubbles and source references
  - Model download card and embedding progress UX
  - Reader toolbar AI chat button integration
affects: [07-audio-tts-stt, 08-desktop-sync]

# Tech tracking
tech-stack:
  added: []
  patterns: [useRAGQuery hook (embed -> search -> LLM pipeline), inverted FlatList chat pattern, KeyboardAvoidingView chat input]

key-files:
  created:
    - apps/mobile/hooks/useRAGQuery.ts
    - apps/mobile/components/ChatMessage.tsx
    - apps/mobile/components/SourceReference.tsx
    - apps/mobile/components/EmbeddingProgress.tsx
    - apps/mobile/components/ModelDownloadCard.tsx
    - apps/mobile/components/ChatInput.tsx
    - apps/mobile/components/ConversationRow.tsx
    - apps/mobile/app/(tabs)/chat.tsx
    - apps/mobile/app/chat/[bookId].tsx
  modified:
    - apps/mobile/components/ui/icon-symbol.tsx
    - apps/mobile/app/(tabs)/_layout.tsx
    - apps/mobile/components/ReaderToolbar.tsx
    - apps/mobile/app/reader/[id].tsx

key-decisions:
  - "RAG system prompt matches desktop version for consistent AI behavior across platforms"
  - "Conversation history limited to last 6 messages in LLM context to manage token budget"
  - "message.fill icon with chat-bubble Android MaterialIcons fallback for Chat tab"

patterns-established:
  - "useRAGQuery hook: embed query -> vector search top-5 -> build context -> Worker LLM call -> return answer with sources"
  - "Inverted FlatList for chat message display with KeyboardAvoidingView"
  - "ModelDownloadCard / EmbeddingProgress cards shown conditionally based on pipeline readiness state"

requirements-completed: [RAG-04, RAG-05, RAG-06, CONV-04]

# Metrics
duration: 8min
completed: 2026-04-06
---

# Phase 6 Plan 5: Chat UI Summary

**RAG query hook, chat UI with conversations list and per-book chat screen, source references, model download/embedding progress UX, and reader toolbar AI integration**

## Performance

- **Duration:** 8 min
- **Started:** 2026-04-06T03:30:00Z
- **Completed:** 2026-04-06T03:38:00Z
- **Tasks:** 3
- **Files modified:** 13

## Accomplishments
- useRAGQuery hook wires embed -> vector search -> Worker LLM into a single async call returning answer + sources
- Chat tab added to bottom navigation with conversations list, empty state, long-press delete, and new-conversation picker
- Per-book chat screen with inverted message list, model download card, embedding progress, typing indicator, and error handling
- Reader toolbar AI button navigates directly to book chat screen
- All 6 chat UI components (ChatMessage, SourceReference, EmbeddingProgress, ModelDownloadCard, ChatInput, ConversationRow) built per UI-SPEC

## Task Commits

Each task was committed atomically:

1. **Task 1: Create RAG query hook and all chat UI components** - `36b956d` (feat)
2. **Task 2: Create chat screens, add Chat tab, and wire reader toolbar** - `f2a7698` (feat)
3. **Task 3: Verify complete RAG and chat feature** - checkpoint approved (no code changes)

## Files Created/Modified
- `apps/mobile/hooks/useRAGQuery.ts` - Hook: embed query -> vector search -> LLM call -> return answer with sources
- `apps/mobile/components/ChatMessage.tsx` - Message bubble with user/assistant styling and source reference chips
- `apps/mobile/components/SourceReference.tsx` - Tappable source reference chip with book icon
- `apps/mobile/components/EmbeddingProgress.tsx` - Progress card for book embedding with chunk count
- `apps/mobile/components/ModelDownloadCard.tsx` - Download prompt or progress bar for AI model
- `apps/mobile/components/ChatInput.tsx` - Bottom input bar with multiline TextInput and send/stop button
- `apps/mobile/components/ConversationRow.tsx` - Conversation list row with book cover, title, preview, and relative time
- `apps/mobile/components/ui/icon-symbol.tsx` - Added message.fill -> chat-bubble Android fallback mapping
- `apps/mobile/app/(tabs)/chat.tsx` - Conversations list tab screen with FlatList and empty state
- `apps/mobile/app/chat/[bookId].tsx` - Per-book chat screen with RAG query flow, model download, and embedding progress
- `apps/mobile/app/(tabs)/_layout.tsx` - Added Chat tab between Library and Explore
- `apps/mobile/components/ReaderToolbar.tsx` - Added onChatPress prop and AI button with message.fill icon
- `apps/mobile/app/reader/[id].tsx` - Wired onChatPress to navigate to chat screen

## Decisions Made
- RAG system prompt matches desktop version for consistent AI behavior across platforms
- Conversation history limited to last 6 messages in LLM context to manage token budget
- message.fill icon with chat-bubble Android MaterialIcons fallback for Chat tab

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- On-Device RAG & AI Conversations phase is now complete (all 5 plans done)
- All RAG infrastructure (chunking, embeddings, vector store, conversation storage, sync, pipeline, server fallback, chat UI) delivered
- Ready for Phase 7 (Audio TTS & STT) which builds on conversation infrastructure

## Self-Check: PASSED

- All 13 key files verified on disk
- Both task commits (36b956d, f2a7698) verified in git log

---
*Phase: 06-on-device-rag-ai-conversations*
*Completed: 2026-04-06*

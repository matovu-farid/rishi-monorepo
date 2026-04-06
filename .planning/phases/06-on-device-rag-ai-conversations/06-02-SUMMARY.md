---
phase: 06-on-device-rag-ai-conversations
plan: 02
subsystem: database, api
tags: [sqlite, drizzle, sync, conversations, messages, crud, lww, append-only]

requires:
  - phase: 04-sync-engine
    provides: sync infrastructure (push/pull, LWW, dirty tracking, Worker routes)
  - phase: 05-highlights-sync
    provides: highlights table pattern, sync engine extension pattern
provides:
  - conversations and messages Drizzle table definitions in shared schema
  - conversation CRUD storage with dirty tracking (conversation-storage.ts)
  - sync engine extended for conversations (LWW) and messages (append-only)
  - Worker sync routes handling all 4 entity types
affects: [06-03-llm-integration, 06-05-chat-ui, 08-desktop-sync]

tech-stack:
  added: [jest, ts-jest]
  patterns: [append-only message sync, auto-title from first user message, conversation-storage CRUD pattern]

key-files:
  created:
    - apps/mobile/lib/conversation-storage.ts
    - apps/mobile/__tests__/conversation.test.ts
    - apps/mobile/__tests__/sync.test.ts
  modified:
    - packages/shared/src/schema.ts
    - packages/shared/src/sync-types.ts
    - apps/mobile/lib/db.ts
    - apps/mobile/lib/sync/engine.ts
    - workers/worker/src/routes/sync.ts

key-decisions:
  - "Conversation conflict type detection via 'title' + 'bookId' fields (not 'filePath') to distinguish from books"
  - "Messages use append-only merge: existing messages are never updated during sync, only new ones inserted"
  - "Pull messages via user's conversation IDs (messages don't have userId directly)"
  - "Jest with ts-jest and schema/drizzle-orm mocks for unit testing (drizzle-orm/sqlite-core not resolvable in node test env)"

patterns-established:
  - "conversation-storage.ts: follows highlight-storage.ts CRUD pattern with dirty tracking and triggerSyncOnWrite"
  - "Append-only sync: messages are immutable once created, pull inserts only, never updates"
  - "Auto-title: first user message content.slice(0, 50) replaces 'New conversation' default"

requirements-completed: [CONV-01, CONV-02, CONV-03]

duration: 11min
completed: 2026-04-06
---

# Phase 06 Plan 02: Conversation Data Model Summary

**Conversations and messages with full CRUD, dirty tracking, and bidirectional sync using LWW for conversations and append-only for messages**

## Performance

- **Duration:** 11 min
- **Started:** 2026-04-06T03:11:24Z
- **Completed:** 2026-04-06T03:22:24Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- Shared schema extended with conversations and messages tables, exported types
- Mobile SQLite migrations create conversations and messages tables on startup
- Full CRUD storage for conversations and messages with dirty tracking and sync triggers
- Sync engine pushes/pulls conversations (LWW) and messages (append-only) across devices
- Worker routes handle all 4 entity types with correct merge strategies
- Global syncVersion spans books, highlights, conversations, and messages
- All 28 tests pass (including 10 new conversation/sync tests)

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend shared schema and sync types** - `39e129d` (feat)
2. **Task 2 RED: Failing tests for conversation CRUD and sync** - `d71536f` (test)
3. **Task 2 GREEN: Implement conversation CRUD, sync engine, worker routes** - `52341eb` (feat)

## Files Created/Modified
- `packages/shared/src/schema.ts` - Added conversations and messages Drizzle table definitions with ConversationRow, NewConversation, MessageRow, NewMessage types
- `packages/shared/src/sync-types.ts` - Extended PushRequest and PullResponse with optional conversations and messages arrays
- `apps/mobile/lib/db.ts` - Added CREATE TABLE migrations for conversations and messages
- `apps/mobile/lib/conversation-storage.ts` - Full CRUD: createConversation, getConversation, getConversationsForBook, getAllConversations, addMessage, getMessages, softDeleteConversation
- `apps/mobile/lib/sync/engine.ts` - Extended push/pull with dirtyConversations/dirtyMessages, LWW for conversations, append-only for messages
- `workers/worker/src/routes/sync.ts` - Extended push handler with conversations (LWW) and messages (append-only) upsert loops, pull handler returns conversations and messages
- `apps/mobile/__tests__/conversation.test.ts` - 8 tests for conversation-storage CRUD
- `apps/mobile/__tests__/sync.test.ts` - 2 tests for sync engine conversation/message push/pull

## Decisions Made
- Conversation conflict type detection uses 'title' + 'bookId' field presence (conversations have title but not filePath, unlike books)
- Messages use append-only merge: once created, they are never updated during sync (immutable)
- Pull messages via user's conversation IDs since messages don't have userId column directly
- Set up Jest with ts-jest and mock @rishi/shared/schema + drizzle-orm to avoid drizzle-orm/sqlite-core resolution issues in node test environment

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Jest test infrastructure setup**
- **Found during:** Task 2 (TDD RED phase)
- **Issue:** No Jest/test framework existed in the mobile app -- needed for TDD tests
- **Fix:** Installed jest + ts-jest, created jest.config.js with path aliases, added schema/drizzle-orm mocks
- **Files modified:** apps/mobile/package.json, apps/mobile/jest.config.js
- **Verification:** All 28 tests pass
- **Committed in:** d71536f (part of RED phase)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Test infrastructure was prerequisite for TDD. No scope creep.

## Issues Encountered
- drizzle-orm/sqlite-core module resolution fails in Jest node environment (it's an ESM-only subpath). Solved by mocking @rishi/shared/schema and drizzle-orm entirely in test files.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Conversation and message data model complete, ready for LLM integration (Plan 03) and chat UI (Plan 05)
- Storage layer provides all CRUD operations the chat UI needs
- Sync engine handles conversations and messages alongside books and highlights

---
*Phase: 06-on-device-rag-ai-conversations*
*Completed: 2026-04-06*

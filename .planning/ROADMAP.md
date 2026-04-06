# Roadmap: Rishi Mobile App

## Overview

This roadmap delivers the Rishi Mobile App from empty scaffold to full desktop parity. The journey starts with build infrastructure and auth (the foundation everything depends on), moves through the two reading formats (EPUB then PDF), builds sync infrastructure, layers on cross-device features (progress, highlights, AI conversations), adds on-device RAG and audio capabilities, and finishes with desktop sync integration. Each phase delivers a coherent, verifiable capability that builds on the previous ones.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation & Auth** - Dev build infrastructure and Clerk authentication flow (completed 2026-04-05)
- [x] **Phase 2: EPUB Reader** - EPUB rendering with pagination, themes, navigation, and file import (completed 2026-04-05)
- [x] **Phase 3: PDF Reader & File Management** - PDF rendering and unified library view for both formats (completed 2026-04-05)
- [x] **Phase 4: Sync Infrastructure** - D1/R2 backend, sync API, and offline-first mobile sync engine (completed 2026-04-05)
- [ ] **Phase 5: Reading Progress & Highlights** - Cross-device reading position, highlights, and annotations
- [ ] **Phase 6: On-Device RAG & AI Conversations** - Text chunking, on-device embeddings, vector search, and AI Q&A
- [ ] **Phase 7: Audio (TTS & STT)** - Text-to-speech playback and speech-to-text voice input
- [ ] **Phase 8: Desktop Sync Integration** - Bidirectional sync between desktop and mobile apps

## Phase Details

### Phase 1: Foundation & Auth
**Goal**: Users can sign in on mobile and make authenticated API calls to the Worker, with the app running as a custom dev build (not Expo Go).
**Depends on**: Nothing (first phase)
**Requirements**: AUTH-01, AUTH-02, AUTH-03, AUTH-04, AUTH-05
**Risk**: Low -- Clerk Expo SDK is well-documented with official quickstart guides
**Research needed**: No
**Success Criteria** (what must be TRUE):
  1. User can sign in with email or social account via Clerk on mobile
  2. User is redirected to sign-in screen when not authenticated
  3. JWT persists across app restarts -- user does not need to re-authenticate on every launch
  4. Authenticated API calls to the Worker succeed; expired tokens trigger re-authentication
  5. App builds and runs as a custom Expo dev client (not Expo Go)
**Plans**: 2 plans

Plans:
- [ ] 01-01-PLAN.md -- Install Clerk SDK, configure ClerkProvider, restructure routes with auth guards, create sign-in screen
- [ ] 01-02-PLAN.md -- Token exchange service, secure JWT storage, API client with auto-refresh on 401, end-to-end verification

### Phase 2: EPUB Reader
**Goal**: Users can import and read EPUB books with a polished reading experience including themes, font controls, and navigation.
**Depends on**: Phase 1
**Requirements**: READ-01, READ-03, READ-04, READ-05, READ-07, FILE-01, FILE-03, FILE-06
**Risk**: Medium -- @epubjs-react-native has 240 stars and last release Jan 2025; WebView memory on low-end Android is a concern
**Research needed**: No -- @epubjs-react-native has clear API docs and examples
**Success Criteria** (what must be TRUE):
  1. User can import an EPUB file from device storage and it appears in the app
  2. User can open and read an EPUB with paginated view
  3. User can switch between light, dark, and sepia themes while reading
  4. User can adjust font size while reading
  5. User can navigate via table of contents
  6. Reading position is saved and restored when reopening a book (ePubCFI)
  7. Imported books are readable without network connection
**Plans**: 3 plans

Plans:
- [ ] 02-01-PLAN.md -- Install dependencies, define types, create SQLite database, book storage service, file import utility
- [ ] 02-02-PLAN.md -- Library screen with book list, empty state, import flow, navigation to reader
- [x] 02-03-PLAN.md -- EPUB reader screen with themes, font controls, TOC navigation, position persistence

### Phase 3: PDF Reader & File Management
**Goal**: Users can import and read PDF books, and browse a unified library showing all their books with metadata.
**Depends on**: Phase 2
**Requirements**: READ-02, READ-06, FILE-02, FILE-04, FILE-05
**Risk**: Low -- react-native-pdf is mature and widely used
**Research needed**: No
**Success Criteria** (what must be TRUE):
  1. User can import a PDF file from device storage
  2. User can open and read a PDF with native rendering
  3. User can navigate PDF via page numbers and thumbnails
  4. User can view a library of all imported books (EPUB and PDF) with title, author, and cover
  5. User can delete books from the library
**Plans**: 2 plans

Plans:
- [ ] 03-01-PLAN.md -- Install react-native-pdf, extend types/DB/import for PDF, create PDF reader screen with page navigation and position persistence
- [ ] 03-02-PLAN.md -- Unified library with format badge, format-aware routing, import chooser, book deletion with file cleanup

### Phase 4: Sync Infrastructure
**Goal**: Books and their metadata sync between mobile devices via Cloudflare D1 and R2, with offline-first local operations.
**Depends on**: Phase 3
**Requirements**: SYNC-01, SYNC-02, SYNC-03, SYNC-04, SYNC-05, SYNC-06, SYNC-07
**Risk**: Medium -- Drizzle schema sharing between D1 and expo-sqlite needs hands-on validation; presigned URL flow needs end-to-end testing
**Research needed**: Yes -- validate Drizzle schema sharing between D1 and expo-sqlite; test presigned URL upload/download flow end-to-end
**Success Criteria** (what must be TRUE):
  1. Book imported on one mobile device appears in the library on another device after sync
  2. Book files upload to R2 on import and download on-demand on other devices
  3. Duplicate book files are deduplicated by content hash (not re-uploaded)
  4. Sync happens automatically on foreground, on write, and periodically
  5. All local operations (reading, importing, browsing library) work without network
**Plans**: 3 plans

Plans:
- [ ] 04-01-PLAN.md -- Shared Drizzle schema package, Worker D1/R2 bindings, sync push/pull API, presigned URL endpoints
- [ ] 04-02-PLAN.md -- Mobile DB migration to Drizzle ORM, sync-aware CRUD with dirty tracking, sync engine with automatic triggers
- [ ] 04-03-PLAN.md -- File hashing and R2 upload on import, on-demand file download for remote books, end-to-end sync verification

### Phase 5: Reading Progress & Highlights
**Goal**: Users can create highlights and annotations in EPUB books, and reading progress and highlights sync across devices.
**Depends on**: Phase 2, Phase 4
**Requirements**: HIGH-01, HIGH-02, HIGH-03, HIGH-04, HIGH-05, HIGH-06, HIGH-07
**Risk**: Low -- ePubCFI sync is well-understood; annotation API is part of @epubjs-react-native
**Research needed**: No
**Success Criteria** (what must be TRUE):
  1. User can create text highlights in EPUB books
  2. User can add notes to highlights and edit them
  3. User can view all highlights for a book in a list and delete individual highlights
  4. Reading position syncs across devices -- opening a book on another device resumes where the user left off
  5. Highlights created on one device appear on another device after sync (no highlight lost)
**Plans**: 3 plans

Plans:
- [ ] 05-01-PLAN.md -- Shared highlights schema, SQLite migration, highlight types, CRUD storage with dirty tracking
- [ ] 05-02-PLAN.md -- EPUB reader highlight UI: text selection, annotation popover, highlights sheet, note editor, toolbar button
- [ ] 05-03-PLAN.md -- Sync engine and Worker routes extended for highlights push/pull with union merge

### Phase 6: On-Device RAG & AI Conversations
**Goal**: Users can ask natural language questions about their books and get AI answers grounded in book content, with conversation history that persists and syncs.
**Depends on**: Phase 2, Phase 3, Phase 4
**Requirements**: RAG-01, RAG-02, RAG-03, RAG-04, RAG-05, RAG-06, RAG-07, RAG-08, CONV-01, CONV-02, CONV-03, CONV-04
**Risk**: High -- ExecuTorch performance on real devices is estimated not measured; embedding model is ~80MB; memory pressure during embedding needs testing
**Research needed**: Yes -- validate ExecuTorch embedding performance on real devices; test react-native-rag vs manual pipeline; measure memory pressure during embedding
**Success Criteria** (what must be TRUE):
  1. After importing a book, its text is chunked and embedded on-device (with progress indicator for model download)
  2. User can ask a natural language question about a book and receive an AI-generated answer
  3. AI answers include references to specific book passages
  4. User can have multi-turn conversations about a book, with history persisting locally
  5. Conversation history syncs across devices
  6. Server-side embedding fallback works for bulk book imports
**Plans**: 5 plans

Plans:
- [ ] 06-01-PLAN.md -- RAG types, EPUB text chunking, sqlite-vec vector store with KNN search
- [ ] 06-02-PLAN.md -- Conversation/message schema, CRUD storage with dirty tracking, sync engine and Worker extension
- [ ] 06-03-PLAN.md -- react-native-executorch setup, embedding pipeline (extract -> chunk -> embed -> store), model download hook
- [ ] 06-04-PLAN.md -- Server-side embedding fallback (Worker /api/embed endpoint + mobile client)
- [ ] 06-05-PLAN.md -- Chat UI (conversations list, per-book chat screen, RAG query hook, source references, reader toolbar integration)

### Phase 7: Audio (TTS & STT)
**Goal**: Users can listen to book content via text-to-speech and ask questions using voice input.
**Depends on**: Phase 6
**Requirements**: AUD-01, AUD-02, AUD-03, AUD-04, AUD-05, AUD-06
**Risk**: Medium -- expo-audio is newer; Deepgram STT Worker endpoint does not exist yet and must be built
**Research needed**: Minimal -- verify TTS response format from Worker; test expo-audio playback pipeline
**Success Criteria** (what must be TRUE):
  1. User can tap play and hear the current book text read aloud via TTS
  2. TTS playback has working play, pause, and stop controls
  3. TTS reads sequentially through book content (not just the current page)
  4. User can ask a question by voice and receive an AI answer
  5. Voice input is transcribed via the Worker Deepgram STT endpoint
**Plans**: TBD

Plans:
- [ ] 07-01: TBD
- [ ] 07-02: TBD

### Phase 8: Desktop Sync Integration
**Goal**: Books, reading progress, highlights, and conversations sync bidirectionally between the desktop Tauri app and mobile.
**Depends on**: Phase 4, Phase 5
**Requirements**: DSYNC-01, DSYNC-02, DSYNC-03, DSYNC-04, DSYNC-05
**Risk**: High -- desktop SQLite migration from integer IDs to UUIDs is delicate; this is a scope expansion requiring desktop app changes
**Research needed**: Yes -- desktop SQLite migration strategy (integer IDs to UUIDs with foreign keys) needs careful planning
**Success Criteria** (what must be TRUE):
  1. Books imported on desktop appear on mobile after sync, and vice versa
  2. Reading progress syncs bidirectionally -- resuming on either device picks up where the other left off
  3. Highlights and annotations created on either device appear on the other
  4. Desktop app uses UUID sync identifiers (migration from integer IDs complete)
  5. Sync logic lives in a shared TypeScript package used by both desktop and mobile
**Plans**: TBD

Plans:
- [ ] 08-01: TBD
- [ ] 08-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation & Auth | 2/2 | Complete   | 2026-04-05 |
| 2. EPUB Reader | 3/3 | Complete | 2026-04-05 |
| 3. PDF Reader & File Management | 2/2 | Complete   | 2026-04-05 |
| 4. Sync Infrastructure | 3/3 | Complete   | 2026-04-05 |
| 5. Reading Progress & Highlights | 0/3 | Not started | - |
| 6. On-Device RAG & AI Conversations | 0/5 | Not started | - |
| 7. Audio (TTS & STT) | 0/? | Not started | - |
| 8. Desktop Sync Integration | 0/? | Not started | - |

## Coverage

| Category | Requirements | Phase | Count |
|----------|-------------|-------|-------|
| Authentication | AUTH-01 through AUTH-05 | Phase 1 | 5 |
| Book Rendering (EPUB) | READ-01, READ-03, READ-04, READ-05, READ-07 | Phase 2 | 5 |
| Book Rendering (PDF) | READ-02, READ-06 | Phase 3 | 2 |
| File Management (EPUB) | FILE-01, FILE-03, FILE-06 | Phase 2 | 3 |
| File Management (PDF/Library) | FILE-02, FILE-04, FILE-05 | Phase 3 | 3 |
| Sync Infrastructure | SYNC-01 through SYNC-07 | Phase 4 | 7 |
| Reading Progress & Highlights | HIGH-01 through HIGH-07 | Phase 5 | 7 |
| On-Device RAG | RAG-01 through RAG-08 | Phase 6 | 8 |
| AI Conversations | CONV-01 through CONV-04 | Phase 6 | 4 |
| Audio | AUD-01 through AUD-06 | Phase 7 | 6 |
| Desktop Sync | DSYNC-01 through DSYNC-05 | Phase 8 | 5 |

**Total: 55/55 v1 requirements mapped. No orphans.**

---
*Roadmap created: 2026-04-05*
*Last updated: 2026-04-06*

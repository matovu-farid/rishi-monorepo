# Requirements: Rishi Mobile App

**Defined:** 2026-04-05
**Core Value:** Users can read their books and interact with AI on their phone with the same experience they get on desktop, with everything synced between devices.

## v1 Requirements

### Authentication

- [x] **AUTH-01**: User can sign in via Clerk on mobile (email, social, or existing account)
- [x] **AUTH-02**: Mobile app exchanges Clerk session token for Worker JWT via existing /api/auth/exchange endpoint
- [x] **AUTH-03**: JWT persists in secure storage across app restarts
- [x] **AUTH-04**: Expired JWT triggers re-authentication flow
- [x] **AUTH-05**: Unauthenticated users are redirected to sign-in screen

### Book Rendering

- [x] **READ-01**: User can open and read an EPUB file with paginated view
- [x] **READ-02**: User can open and read a PDF file with native rendering
- [x] **READ-03**: EPUB reader supports theme switching (light, dark, sepia)
- [x] **READ-04**: EPUB reader supports font size adjustment
- [x] **READ-05**: User can navigate EPUB via table of contents
- [ ] **READ-06**: User can navigate PDF via page numbers and thumbnails
- [x] **READ-07**: Reading position is tracked and restored on reopen (ePubCFI for EPUB, page number for PDF)

### File Management

- [x] **FILE-01**: User can import EPUB files from device storage via file picker
- [x] **FILE-02**: User can import PDF files from device storage via file picker
- [x] **FILE-03**: Imported books are copied to app document directory
- [x] **FILE-04**: User can view library of all imported books with metadata (title, author, cover)
- [x] **FILE-05**: User can delete books from library
- [x] **FILE-06**: Books are available for offline reading after import

### Sync Infrastructure

- [x] **SYNC-01**: Cloudflare D1 schema created for sync metadata (books, progress, highlights, conversations)
- [x] **SYNC-02**: Cloudflare R2 configured for book file storage with hash-based deduplication
- [x] **SYNC-03**: Worker exposes push/pull sync API endpoints authenticated by JWT
- [x] **SYNC-04**: Mobile app syncs on foreground, on write, and periodically (every 5 min)
- [x] **SYNC-05**: Book files upload to R2 via presigned URLs on import
- [x] **SYNC-06**: Book files download from R2 on-demand (lazy download) with local cache
- [x] **SYNC-07**: Sync works offline-first — all local operations succeed without network

### Reading Progress & Highlights

- [ ] **HIGH-01**: User can create text highlights in EPUB books
- [ ] **HIGH-02**: User can add notes to highlights
- [ ] **HIGH-03**: User can view list of all highlights for a book
- [ ] **HIGH-04**: User can delete highlights
- [ ] **HIGH-05**: Reading progress syncs across devices (ePubCFI for EPUB, page for PDF)
- [ ] **HIGH-06**: Highlights sync across devices with union merge (no highlight lost)
- [ ] **HIGH-07**: Annotations sync across devices with LWW per field

### On-Device RAG

- [ ] **RAG-01**: Books are chunked into text segments after import
- [ ] **RAG-02**: Text chunks are embedded on-device using all-MiniLM-L6-v2 via ExecuTorch
- [ ] **RAG-03**: Embeddings stored in expo-sqlite with sqlite-vec extension
- [ ] **RAG-04**: User can ask natural language questions about a book
- [ ] **RAG-05**: Relevant chunks retrieved via semantic vector search
- [ ] **RAG-06**: Retrieved chunks sent to Worker LLM endpoint for answer generation
- [ ] **RAG-07**: Embedding model downloads on first use with progress indicator
- [ ] **RAG-08**: Server-side embedding fallback available for bulk book imports

### Audio

- [ ] **AUD-01**: User can listen to book text via TTS (Worker /api/audio/speech endpoint)
- [ ] **AUD-02**: TTS playback has play/pause/stop controls
- [ ] **AUD-03**: TTS reads sequentially through book content with queue management
- [ ] **AUD-04**: User can ask voice questions via speech input
- [ ] **AUD-05**: Voice input transcribed via Worker Deepgram STT endpoint
- [ ] **AUD-06**: Worker Deepgram STT endpoint created for transcription

### AI Conversations

- [ ] **CONV-01**: User can have multi-turn AI conversations about a book
- [ ] **CONV-02**: Conversation history persists locally per book
- [ ] **CONV-03**: Conversation history syncs across devices (append-only)
- [ ] **CONV-04**: AI responses include source references to book passages

### Desktop Sync Integration

- [ ] **DSYNC-01**: Desktop SQLite schema migrated to include UUID sync identifiers
- [ ] **DSYNC-02**: Desktop app gains push/pull sync engine using shared TypeScript package
- [ ] **DSYNC-03**: Books imported on desktop sync to mobile and vice versa
- [ ] **DSYNC-04**: Reading progress syncs bidirectionally between desktop and mobile
- [ ] **DSYNC-05**: Highlights and annotations sync bidirectionally

## v2 Requirements

### Enhanced Reading

- **READ-V2-01**: PDF annotation creation (highlights, notes on PDF)
- **READ-V2-02**: Full-text search within books
- **READ-V2-03**: Bookmarks (separate from highlights)
- **READ-V2-04**: Reading statistics (time spent, pages per session)

### Enhanced Audio

- **AUD-V2-01**: Real-time streaming STT via WebSocket to Deepgram
- **AUD-V2-02**: Background TTS playback (continues when app is backgrounded)
- **AUD-V2-03**: TTS voice selection

### Enhanced Sync

- **SYNC-V2-01**: Real-time sync notifications via WebSocket/SSE
- **SYNC-V2-02**: Embedding vectors sync across devices (avoid re-embedding)
- **SYNC-V2-03**: Selective sync (choose which books to download on mobile)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Push notifications | Not in desktop parity scope |
| Monetization / payments | Not in current scope |
| Social / sharing features | Not in current scope |
| Marketing website changes | Separate concern |
| Book store / purchasing | Out of scope for v1 |
| OPDS catalog support | Out of scope for v1 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| AUTH-01 | Phase 1 | Complete |
| AUTH-02 | Phase 1 | Complete |
| AUTH-03 | Phase 1 | Complete |
| AUTH-04 | Phase 1 | Complete |
| AUTH-05 | Phase 1 | Complete |
| READ-01 | Phase 2 | Complete |
| READ-02 | Phase 3 | Complete |
| READ-03 | Phase 2 | Complete |
| READ-04 | Phase 2 | Complete |
| READ-05 | Phase 2 | Complete |
| READ-06 | Phase 3 | Pending |
| READ-07 | Phase 2 | Complete |
| FILE-01 | Phase 2 | Complete |
| FILE-02 | Phase 3 | Complete |
| FILE-03 | Phase 2 | Complete |
| FILE-04 | Phase 3 | Complete |
| FILE-05 | Phase 3 | Complete |
| FILE-06 | Phase 2 | Complete |
| SYNC-01 | Phase 4 | Complete |
| SYNC-02 | Phase 4 | Complete |
| SYNC-03 | Phase 4 | Complete |
| SYNC-04 | Phase 4 | Complete |
| SYNC-05 | Phase 4 | Complete |
| SYNC-06 | Phase 4 | Complete |
| SYNC-07 | Phase 4 | Complete |
| HIGH-01 | Phase 5 | Pending |
| HIGH-02 | Phase 5 | Pending |
| HIGH-03 | Phase 5 | Pending |
| HIGH-04 | Phase 5 | Pending |
| HIGH-05 | Phase 5 | Pending |
| HIGH-06 | Phase 5 | Pending |
| HIGH-07 | Phase 5 | Pending |
| RAG-01 | Phase 6 | Pending |
| RAG-02 | Phase 6 | Pending |
| RAG-03 | Phase 6 | Pending |
| RAG-04 | Phase 6 | Pending |
| RAG-05 | Phase 6 | Pending |
| RAG-06 | Phase 6 | Pending |
| RAG-07 | Phase 6 | Pending |
| RAG-08 | Phase 6 | Pending |
| AUD-01 | Phase 7 | Pending |
| AUD-02 | Phase 7 | Pending |
| AUD-03 | Phase 7 | Pending |
| AUD-04 | Phase 7 | Pending |
| AUD-05 | Phase 7 | Pending |
| AUD-06 | Phase 7 | Pending |
| CONV-01 | Phase 6 | Pending |
| CONV-02 | Phase 6 | Pending |
| CONV-03 | Phase 6 | Pending |
| CONV-04 | Phase 6 | Pending |
| DSYNC-01 | Phase 8 | Pending |
| DSYNC-02 | Phase 8 | Pending |
| DSYNC-03 | Phase 8 | Pending |
| DSYNC-04 | Phase 8 | Pending |
| DSYNC-05 | Phase 8 | Pending |

**Coverage:**
- v1 requirements: 51 total
- Mapped to phases: 51
- Unmapped: 0

---
*Requirements defined: 2026-04-05*
*Last updated: 2026-04-05 after initial definition*

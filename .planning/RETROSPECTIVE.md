# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — Rishi Mobile App

**Shipped:** 2026-04-07
**Phases:** 11 | **Plans:** 31

### What Was Built
- Full mobile reading app (EPUB + PDF) with Clerk auth, themes, font controls, TOC, position persistence
- Offline-first cloud sync (D1/R2) with LWW conflict resolution and shared TypeScript engine
- On-device RAG pipeline: ExecuTorch embeddings, sqlite-vec vector search, AI Q&A with source refs
- Cross-device sync for books, reading progress, highlights, annotations, and AI conversations
- TTS playback with queue/caching, voice input via Deepgram STT, OpenAI Realtime voice chat
- Desktop feature parity (highlights UI, reader settings, voice input, source refs, write-triggered sync)
- Mobile feature parity (realtime voice, AI guardrails, sync status indicator, Sentry tracking)

### What Worked
- Phase-based execution with clear success criteria kept scope focused
- Shared TypeScript sync engine avoided duplication between desktop and mobile
- On-device-first with server fallback gave best UX while handling edge cases
- Gap closure phases (9) effectively addressed audit findings without scope creep
- Parity phases (10, 11) systematically closed feature gaps between platforms

### What Was Inefficient
- ROADMAP progress table wasn't updated for phases 5, 7, 9 — caused confusion about completion status
- Audit found integration gaps (getBookById vs getBookForReading) that could have been caught during Phase 6 execution
- Desktop sync (Phase 8) was originally out of scope but became necessary — earlier scoping would have saved replanning

### Patterns Established
- Shared schema package (`@rishi/shared`) for D1 and mobile SQLite parity
- SyncDbAdapter interface pattern for platform-specific sync implementations
- embedBatchWithFallback pattern: try on-device, catch and fall back to server
- vi.hoisted mock chain pattern for Kysely tests in vitest
- Singleton forward function pattern for using React hooks outside React context

### Key Lessons
1. Audit milestones before completion — Phase 9 gap closure was only possible because the audit surfaced broken E2E flows
2. Integration gaps between features (sync + RAG) are the hardest bugs to catch — design cross-feature tests early
3. Platform parity phases work best as dedicated phases, not ad-hoc additions to existing phases
4. PDF thumbnails (READ-06) were the right call to descope — low impact, high effort

### Cost Observations
- 31 plans executed across ~3 days
- Most plans completed in 2-15 minutes (per velocity metrics)
- Outliers: Phase 10 Plans 02/03 took 35-45 minutes due to complex desktop UI integration

---

## Milestone: v1.1 — PDF Thumbnail Navigation

**Shipped:** 2026-04-07
**Phases:** 1 | **Plans:** 2

### What Was Built
- Desktop virtualized thumbnail sidebar using react-pdf Thumbnail + @tanstack/react-virtual in a Sheet panel
- Mobile thumbnail modal with native react-native-pdf-thumbnail generation in a FlatList grid
- BookNavigationState race condition fix for reliable thumbnail click navigation

### What Worked
- Single-phase milestone kept scope tight — shipped same day as planned
- Parallel plan execution (desktop + mobile) was efficient — no cross-plan dependencies
- Research phase identified the BookNavigationState race condition before it became a bug
- Plan checker caught Wave 0 test gap and race condition — both fixed before execution

### What Was Inefficient
- Old v1.0 gap closure phase directories (12, 13) lingered and confused init tools — had to manually clean up
- Phase 12 directory was named `fix-api-contract-mismatches` from old scope — renaming mid-flight caused tool confusion

### Patterns Established
- `pdfDocumentProxyAtom` pattern: capture PDFDocumentProxy in atom to avoid double-loading PDF in separate Document components
- Native thumbnail generation with `PdfThumbnail.generate` per visible FlatList item — lazy, avoids upfront batch generation

### Key Lessons
1. Clean up stale phase directories before starting new milestones — init tools resolve by directory name
2. Single-feature milestones are fast and clean — no coordination overhead
3. Plan checker verification loop adds real value — caught 2 blockers that would have caused execution failures

### Cost Observations
- 2 plans executed in ~8 minutes total (parallel)
- Research + planning + verification took longer than execution
- Single session, same day as v1.0 completion

---

## Cross-Milestone Trends

| Metric | v1.0 | v1.1 |
|--------|------|------|
| Phases | 11 | 1 |
| Plans | 31 | 2 |
| Avg plan duration | ~8 min | ~4 min |
| Audit gaps found | 2 req + 2 integration | 0 |
| Gaps closed | All except READ-06 | READ-06 (PDF thumbnails) |

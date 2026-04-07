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

## Cross-Milestone Trends

| Metric | v1.0 |
|--------|------|
| Phases | 11 |
| Plans | 31 |
| Avg plan duration | ~8 min |
| Audit gaps found | 2 req + 2 integration |
| Gaps closed | All except READ-06 (descoped) |

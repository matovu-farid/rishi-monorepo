# Roadmap: Rishi Mobile App

## Milestones

- ✅ **v1.0 Rishi Mobile App** — Phases 1-11 (shipped 2026-04-07)
- 🚧 **v1.1 PDF Thumbnail Navigation** — Phase 12 (in progress)

## Phases

<details>
<summary>v1.0 Rishi Mobile App (Phases 1-11) — SHIPPED 2026-04-07</summary>

- [x] Phase 1: Foundation & Auth (2/2 plans) — completed 2026-04-05
- [x] Phase 2: EPUB Reader (3/3 plans) — completed 2026-04-05
- [x] Phase 3: PDF Reader & File Management (2/2 plans) — completed 2026-04-05
- [x] Phase 4: Sync Infrastructure (3/3 plans) — completed 2026-04-05
- [x] Phase 5: Reading Progress & Highlights (4/4 plans) — completed 2026-04-05
- [x] Phase 6: On-Device RAG & AI Conversations (5/5 plans) — completed 2026-04-06
- [x] Phase 7: Audio (TTS & STT) (2/2 plans) — completed 2026-04-06
- [x] Phase 8: Desktop Sync Integration (3/3 plans) — completed 2026-04-06
- [x] Phase 9: Synced-Book Data Path Fixes (1/1 plan) — completed 2026-04-06
- [x] Phase 10: Desktop Feature Parity (3/3 plans) — completed 2026-04-06
- [x] Phase 11: Mobile Feature Parity (3/3 plans) — completed 2026-04-07

Full details: [milestones/v1.0-ROADMAP.md](milestones/v1.0-ROADMAP.md)

**v1.0 Gap Closure:**
- Phase 12 (API Contract Mismatches): COMPLETED 2026-04-07 (1/1 plan) -- fixed desktop chat, Worker client_secrets, and mobile guardrails API contracts
- Phase 13 (PDF Thumbnails) scope is now covered by v1.1.

</details>

### v1.1 PDF Thumbnail Navigation (In Progress)

**Milestone Goal:** Users can visually browse and jump between PDF pages using a thumbnail sidebar.

- [x] **Phase 12: PDF Thumbnail Sidebar** - Thumbnail navigation for quick page jumping in PDF reader (completed 2026-04-07)

## Phase Details

### Phase 12: PDF Thumbnail Sidebar
**Goal**: Users can visually browse and navigate PDF pages through a thumbnail sidebar
**Depends on**: v1.0 complete (Phase 11)
**Requirements**: PDFT-01, PDFT-02, PDFT-03, PDFT-04, PDFT-05
**Success Criteria** (what must be TRUE):
  1. User can open and close a thumbnail sidebar while reading a PDF without losing their reading position
  2. User sees page preview images for every page in the document within the sidebar
  3. User can identify which page they are currently reading by its visual highlight in the sidebar
  4. User can tap any thumbnail to instantly navigate to that page
  5. User experiences no perceptible lag or freeze when opening the sidebar on a 100+ page PDF
**Plans**: 2 plans

Plans:
- [ ] 12-01-PLAN.md — Desktop thumbnail sidebar with virtualized react-pdf Thumbnails
- [ ] 12-02-PLAN.md — Mobile thumbnail modal with native react-native-pdf-thumbnail

## Progress

**Execution Order:**
Phases execute in numeric order.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-11 | v1.0 | 31/31 | Complete | 2026-04-07 |
| 12. PDF Thumbnail Sidebar | 2/2 | Complete   | 2026-04-07 | - |

---
*Roadmap created: 2026-04-05*
*Last updated: 2026-04-07 after Phase 12 planning*

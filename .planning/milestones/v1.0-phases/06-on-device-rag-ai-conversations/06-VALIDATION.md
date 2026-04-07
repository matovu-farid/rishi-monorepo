---
phase: 06
slug: on-device-rag-ai-conversations
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 06 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | jest 29.x (via expo) |
| **Config file** | apps/mobile/jest.config.js |
| **Quick run command** | `cd apps/mobile && npx jest --passWithNoTests --no-coverage -q` |
| **Full suite command** | `cd apps/mobile && npx jest --no-coverage` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd apps/mobile && npx jest --passWithNoTests --no-coverage -q`
- **After every plan wave:** Run `cd apps/mobile && npx jest --no-coverage`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | RAG-01 | unit | `npx jest chunker` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | RAG-02 | integration | `npx jest embedding` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 1 | RAG-03, RAG-04 | unit | `npx jest vector` | ❌ W0 | ⬜ pending |
| 06-03-01 | 03 | 2 | RAG-05, RAG-06 | integration | `npx jest rag-pipeline` | ❌ W0 | ⬜ pending |
| 06-03-02 | 03 | 2 | CONV-01, CONV-02 | unit | `npx jest conversation` | ❌ W0 | ⬜ pending |
| 06-04-01 | 04 | 2 | CONV-03, CONV-04 | unit | `npx jest sync` | ❌ W0 | ⬜ pending |
| 06-04-02 | 04 | 2 | RAG-07, RAG-08 | integration | `npx jest fallback` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `apps/mobile/__tests__/chunker.test.ts` — stubs for RAG-01 text chunking
- [ ] `apps/mobile/__tests__/embedding.test.ts` — stubs for RAG-02 embedding generation
- [ ] `apps/mobile/__tests__/vector.test.ts` — stubs for RAG-03/RAG-04 vector storage and search
- [ ] `apps/mobile/__tests__/rag-pipeline.test.ts` — stubs for RAG-05/RAG-06 pipeline integration
- [ ] `apps/mobile/__tests__/conversation.test.ts` — stubs for CONV-01/CONV-02 conversation persistence
- [ ] `apps/mobile/__tests__/sync.test.ts` — stubs for CONV-03/CONV-04 conversation sync

*Existing infrastructure covers test framework — only test file stubs needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Model download progress indicator | RAG-02 | Visual UI element dependent on real download | Import book, observe model download progress bar |
| On-device embedding performance | RAG-01 | Requires real ExecuTorch model execution | Time embedding of a 50-chapter book on physical device |
| AI answer references book passages | RAG-06 | LLM output quality assessment | Ask question about book, verify cited passages match content |
| Cross-device conversation sync | CONV-03 | Requires two running devices | Create conversation on device A, verify appears on device B |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

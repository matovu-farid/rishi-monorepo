---
phase: 9
slug: synced-book-data-path-fixes
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Jest + ts-jest |
| **Config file** | apps/mobile/jest.config.js |
| **Quick run command** | `cd apps/mobile && npx jest --no-coverage --reporter=verbose` |
| **Full suite command** | `cd apps/mobile && npx jest --no-coverage` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `npx tsc --noEmit`
- **After every plan wave:** Run full suite command
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 09-01-01 | 01 | 1 | RAG-08 | unit | `cd apps/mobile && npx jest --testPathPattern="rag-pipeline" --no-coverage` | Exists (needs fallback tests) | pending |
| 09-01-02 | 01 | 1 | RAG-08 | compilation | `cd apps/mobile && npx tsc --noEmit` | N/A (type check) | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] Test stubs for pipeline.ts server fallback behavior (added in Task 1 TDD cycle)

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Synced book opens in chat and returns RAG answers | RAG-08 | Requires live R2 download + on-device embedding or server fallback | Import book on desktop, sync to mobile, open chat, ask question |
| Server fallback triggers when model not downloaded | RAG-08 | Requires fresh install without model | Uninstall model, open chat for a book, verify embedding completes via server |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

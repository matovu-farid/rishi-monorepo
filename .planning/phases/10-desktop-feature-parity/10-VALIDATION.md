---
phase: 10
slug: desktop-feature-parity
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Vitest |
| **Config file** | `apps/main/vitest.config.ts` |
| **Quick run command** | `cd apps/main && npx vitest run --reporter=verbose` |
| **Full suite command** | `cd apps/main && npx vitest run` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd apps/main && npx vitest run --reporter=verbose`
- **After every plan wave:** Run `cd apps/main && npx vitest run`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | PARITY-D01 | unit | `cd apps/main && npx vitest run src/modules/highlight-storage.test.ts -x` | ❌ W0 | ⬜ pending |
| 10-01-02 | 01 | 1 | PARITY-D02 | unit | `cd apps/main && npx vitest run src/modules/highlight-storage.test.ts -x` | ❌ W0 | ⬜ pending |
| 10-02-01 | 02 | 1 | PARITY-D03 | manual | N/A (rendition mock complex) | N/A | ⬜ pending |
| 10-03-01 | 03 | 1 | PARITY-D04 | manual | N/A (requires mic/network) | N/A | ⬜ pending |
| 10-04-01 | 04 | 1 | PARITY-D05 | unit | `cd apps/main && npx vitest run src/modules/embed-fallback.test.ts -x` | ❌ W0 | ⬜ pending |
| 10-05-01 | 05 | 1 | PARITY-D06 | unit | `cd apps/main && npx vitest run src/modules/sync-triggers.test.ts -x` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `apps/main/src/modules/highlight-storage.test.ts` — stubs for PARITY-D01, PARITY-D02
- [ ] `apps/main/src/modules/embed-fallback.test.ts` — stubs for PARITY-D05
- [ ] `apps/main/src/modules/sync-triggers.test.ts` — stubs for PARITY-D06

*Existing infrastructure covers PARITY-D03 and PARITY-D04 via manual verification.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Reader settings (font size, family) | PARITY-D03 | epub.js rendition mock is complex; visual verification needed | 1. Open book in desktop reader 2. Click settings gear icon 3. Adjust font size slider — text should resize 4. Toggle font family — text should change between serif/sans-serif |
| Voice input recording + transcription | PARITY-D04 | Requires microphone hardware and network for STT | 1. Open chat panel 2. Click mic button 3. Speak a question 4. Release mic — transcript should appear in chat input |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

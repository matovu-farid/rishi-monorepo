---
phase: 12
slug: pdf-thumbnail-sidebar
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-07
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Vitest (desktop) |
| **Config file** | apps/main/vitest.config.ts |
| **Quick run command** | `cd apps/main && npx vitest run --reporter=verbose` |
| **Full suite command** | `cd apps/main && npx vitest run` |
| **Estimated runtime** | ~10 seconds |

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
| 12-01-01 | 01 | 1 | PDFT-01 | manual-only | N/A - requires PDF rendering in browser | N/A | ⬜ pending |
| 12-01-02 | 01 | 1 | PDFT-02 | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | ❌ W0 | ⬜ pending |
| 12-01-03 | 01 | 1 | PDFT-03 | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | ❌ W0 | ⬜ pending |
| 12-01-04 | 01 | 1 | PDFT-04 | unit | `cd apps/main && npx vitest run src/components/pdf/components/thumbnail-sidebar.test.tsx -x` | ❌ W0 | ⬜ pending |
| 12-01-05 | 01 | 1 | PDFT-05 | unit | `cd apps/main && npx vitest run src/components/pdf/hooks/useThumbnailVirtualization.test.tsx -x` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `apps/main/src/components/pdf/components/thumbnail-sidebar.test.tsx` — stubs for PDFT-02, PDFT-03, PDFT-04
- [ ] `apps/main/src/components/pdf/hooks/useThumbnailVirtualization.test.tsx` — stubs for PDFT-05
- Mobile tests are manual-only (React Native PDF rendering cannot be unit tested meaningfully)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Sidebar opens/closes without losing reading position | PDFT-01 | Requires PDF rendering in browser DOM | 1. Open a PDF, navigate to page 5. 2. Open thumbnail sidebar. 3. Verify page 5 still visible. 4. Close sidebar. 5. Verify still on page 5. |
| Mobile thumbnail modal opens and navigates | PDFT-01-04 (mobile) | React Native PDF rendering untestable in unit tests | 1. Open PDF on mobile. 2. Tap thumbnail button. 3. Verify thumbnails appear. 4. Tap a thumbnail. 5. Verify navigation. |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

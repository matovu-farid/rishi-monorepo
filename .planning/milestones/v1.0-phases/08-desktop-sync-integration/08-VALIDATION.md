---
phase: 8
slug: desktop-sync-integration
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 8 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | vitest (web/mobile), cargo test (Tauri/Rust) |
| **Config file** | `apps/web/vitest.config.ts`, `apps/main/src-tauri/Cargo.toml` |
| **Quick run command** | `cd apps/web && npx vitest run --reporter=verbose` |
| **Full suite command** | `cd apps/web && npx vitest run && cd ../../apps/main/src-tauri && cargo test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd apps/web && npx vitest run --reporter=verbose`
- **After every plan wave:** Run full suite command
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 08-01-01 | 01 | 1 | DSYNC-04 | unit | `cargo test migration` | ❌ W0 | ⬜ pending |
| 08-01-02 | 01 | 1 | DSYNC-04 | unit | `cargo test sync_id` | ❌ W0 | ⬜ pending |
| 08-02-01 | 02 | 2 | DSYNC-05 | unit | `npx vitest run sync-adapter` | ❌ W0 | ⬜ pending |
| 08-02-02 | 02 | 2 | DSYNC-01 | integration | `npx vitest run desktop-push-pull` | ❌ W0 | ⬜ pending |
| 08-03-01 | 03 | 2 | DSYNC-02 | integration | `npx vitest run progress-sync` | ❌ W0 | ⬜ pending |
| 08-03-02 | 03 | 2 | DSYNC-03 | integration | `npx vitest run highlight-sync` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Test stubs for desktop SQLite migration (Rust unit tests)
- [ ] Test stubs for sync adapter (TypeScript vitest)
- [ ] Test stubs for bidirectional sync integration tests

*Existing vitest and cargo test infrastructure covers framework needs.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Book appears on mobile after desktop import + sync | DSYNC-01 | End-to-end cross-device | Import book on desktop, trigger sync, verify on mobile |
| Reading position resumes on other device | DSYNC-02 | Cross-device state | Read on desktop to position X, sync, verify mobile resumes at X |
| Cover image displays correctly after sync | DSYNC-01 | Visual verification | Import book with cover on desktop, sync, check mobile renders cover |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

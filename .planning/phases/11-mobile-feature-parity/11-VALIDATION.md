---
phase: 11
slug: mobile-feature-parity
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | jest (React Native) + manual device testing |
| **Config file** | `apps/mobile/jest.config.js` or "none — Wave 0 installs" |
| **Quick run command** | `cd apps/mobile && npx jest --passWithNoTests` |
| **Full suite command** | `cd apps/mobile && npx jest` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd apps/mobile && npx jest --passWithNoTests`
- **After every plan wave:** Run `cd apps/mobile && npx jest`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 11-01-01 | 01 | 1 | PARITY-M04 | unit | `cd apps/mobile && npx jest --testPathPattern sentry` | ❌ W0 | ⬜ pending |
| 11-02-01 | 02 | 1 | PARITY-M03 | unit | `cd apps/mobile && npx jest --testPathPattern sync-status` | ❌ W0 | ⬜ pending |
| 11-03-01 | 03 | 2 | PARITY-M01 | integration | `cd apps/mobile && npx jest --testPathPattern realtime` | ❌ W0 | ⬜ pending |
| 11-03-02 | 03 | 2 | PARITY-M02 | unit | `cd apps/mobile && npx jest --testPathPattern guardrail` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Jest test infrastructure verified/installed in `apps/mobile/`
- [ ] `apps/mobile/__tests__/` directory with test stubs for PARITY-M01 through PARITY-M04
- [ ] Shared test fixtures for mocking WebRTC, Sentry, and sync engine

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live voice conversation with AI | PARITY-M01 | Requires real audio I/O, microphone permissions, and OpenAI Realtime WebRTC connection | 1. Open book in mobile app, 2. Tap voice chat button, 3. Speak a question about the book, 4. Verify AI responds audibly with relevant content |
| Guardrail interrupts off-topic response | PARITY-M02 | Requires real LLM output to trigger tripwire classification | 1. During voice chat, prompt AI for off-topic content, 2. Verify audio is interrupted and user sees guardrail message |
| Sync status indicator shows correct states | PARITY-M03 | Requires network state changes on physical device | 1. Observe "synced" state, 2. Toggle airplane mode, 3. Verify "offline" state appears, 4. Re-enable network, 5. Verify "syncing" then "synced" transition |
| Sentry captures crash report | PARITY-M04 | Requires triggering real crash and verifying Sentry dashboard | 1. Trigger a test crash in dev build, 2. Check Sentry project for new event with session data |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

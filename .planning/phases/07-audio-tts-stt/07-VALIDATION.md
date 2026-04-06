---
phase: 7
slug: audio-tts-stt
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Jest 30.x + ts-jest 29.x |
| **Config file** | `apps/mobile/jest.config.js` |
| **Quick run command** | `cd apps/mobile && npx jest --testPathPattern=__tests__/tts` |
| **Full suite command** | `cd apps/mobile && npx jest` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd apps/mobile && npx jest --testPathPattern=__tests__/tts`
- **After every plan wave:** Run `cd apps/mobile && npx jest`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 07-01-01 | 01 | 1 | AUD-01, AUD-03 | unit | `cd apps/mobile && npx jest __tests__/tts/tts-queue.test.ts -x` | ❌ W0 | ⬜ pending |
| 07-01-02 | 01 | 1 | AUD-02 | unit | `cd apps/mobile && npx jest __tests__/tts/tts-player.test.ts -x` | ❌ W0 | ⬜ pending |
| 07-02-01 | 02 | 1 | AUD-06 | manual | curl test against deployed Worker | N/A | ⬜ pending |
| 07-02-02 | 02 | 1 | AUD-04, AUD-05 | unit + manual | `cd apps/mobile && npx jest __tests__/tts/voice-input.test.ts -x` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `apps/mobile/__tests__/tts/tts-queue.test.ts` — stubs for AUD-01, AUD-03
- [ ] `apps/mobile/__tests__/tts/tts-player.test.ts` — stubs for AUD-02
- [ ] `apps/mobile/__tests__/tts/voice-input.test.ts` — stubs for AUD-05

*Existing jest infrastructure covers framework requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Voice recording produces audio file | AUD-04 | Requires device microphone hardware | Press mic button, speak, verify recording URI is non-null |
| Worker STT endpoint responds | AUD-06 | Requires deployed Worker with DEEPGRAM_KEY | `curl -X POST https://worker-url/api/audio/transcribe -H "Authorization: Bearer <token>" -H "Content-Type: audio/webm" --data-binary @test.webm` |
| TTS audio plays through device speaker | AUD-01 | Requires device audio output | Open book, tap play, hear audio |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

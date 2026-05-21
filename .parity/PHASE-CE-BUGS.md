# Phase C + E — Bugs Found During Coverage Fill

Loop B Phase C (voice-chat realtime-session) and Phase E (long-tail edge
cases) are TDD-only — write tests, log bugs found, leave fixes for
Loop C.

---

## Summary

**No implementation bugs were found while adding the Phase C + E tests.**

All 27 new tests passed against the current implementations:

| Audit ID | Test file | Status |
| -------- | --------- | ------ |
| CG06 | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG07 | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG28 (mic-denied) | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG29 (key 401, no signOut) | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG28 (interrupt) | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG29 (updateAgent) | `__tests__/voice-chat/realtime-session.test.ts` | green |
| CG10 | `__tests__/auth/auth-resign-in.test.ts` | green |
| CG17 | `__tests__/rag/chunker-epub.test.ts` | green |
| CG19 | `__tests__/onboarding/tour-resume.test.ts` | green |
| CG21 | `__tests__/tts/epub-read-from-selection.test.tsx` | green |
| CG30 | `__tests__/auth/auth-rate-limit.test.ts` | green |
| CG40 | `__tests__/voice-chat/inactivity.test.ts` | green |

---

## Coverage decisions worth noting (not bugs)

### CG19 — `tourStep` is intentionally NOT persisted across cold-start

The audit row CG19 suggested testing "tour resumes at the saved
tourStep after store rehydrates from MMKV". Spot-check against
`apps/rishi-electron/.../tutorialStore.ts` (the parity source) shows
electron ALSO does not persist `tourStep` — only `tourCompleted` and
`hintsShown`. The mobile behaviour therefore matches electron.

`__tests__/onboarding/tour-resume.test.ts` pins this cold-start contract
explicitly so a future refactor doesn't silently add tourStep
persistence without an explicit electron-parity decision.

### CG20 — already covered by Phase A

Phase A added a skipped test (`__tests__/settings/settings.test.tsx`
"Sign-out still clears the auth store when lib/auth.signOut throws") and
documented the underlying unhandled-rejection issue as PA-01 in
`.parity/PHASE-A-BUGS.md`. No additional Phase E test was added — that
would have created duplicate coverage.

### CG22 — covered by Phase A

Phase A created
`__tests__/pdf/pdf-reader-highlight-tap.test.tsx` (labeled CG16
internally — there's a small numbering overlap in the audit, but the
substance matches CG22: PdfWebReader routes `highlightTapped` →
`onHighlightTapped` and the reader screen opens the recolor/delete
picker). No additional Phase E test was added.

### CG30 — pinned at the mobile client side, not the worker side

The audit suggested extending `workers/worker/src/routes/mobile.test.ts`
with a Retry-After header assertion. Setting that up cleanly requires
fully wiring Better-Auth's rate-limit machinery in vitest, which is
disproportionate to the value. Phase E pins the more useful
contract at the mobile client end: when /mobile/start returns 429,
`signIn()` rejects without opening a browser or persisting a token.
See `__tests__/auth/auth-rate-limit.test.ts`.

If Loop C still wants the worker-side coverage, the natural extension
point is adding one rate-limit-aware test to
`workers/worker/src/routes/mobile.test.ts` using Better-Auth's
in-memory limiter; that's a separate effort.

---

_End of Phase C + E bug log._

---
phase: 12-fix-api-contract-mismatches
plan: 01
subsystem: api
tags: [hono, fetch, json, api-contract, desktop, mobile, worker]

# Dependency graph
requires:
  - phase: 06-on-device-rag-ai-conversations
    provides: Desktop useChat hook, mobile realtime session and guardrails
  - phase: 09-synced-book-data-path-fixes
    provides: Worker endpoints for text completions and realtime client secrets
provides:
  - Aligned desktop chat API contract (request body key + response parsing)
  - Aligned Worker client_secrets JSON response shape for mobile realtime
  - Aligned mobile guardrails response parsing with Worker c.json() envelope
affects: [10-desktop-feature-parity, 11-mobile-feature-parity]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Worker c.json() returns JSON-wrapped values; clients must use response.json() not response.text()"
    - "OpenAI Responses API uses `input` not `messages` for the conversation array"

key-files:
  created: []
  modified:
    - apps/main/src/hooks/useChat.ts
    - workers/worker/src/index.ts
    - apps/mobile/lib/realtime/guardrails.ts

key-decisions:
  - "Surgical fixes only -- changed minimum lines to align contracts without refactoring"

patterns-established:
  - "API contract alignment: always verify client request/response shapes against Worker handler destructuring and return types"

requirements-completed: [PARITY-D04, PARITY-M01, PARITY-M02]

# Metrics
duration: 2min
completed: 2026-04-07
---

# Phase 12 Plan 01: Fix API Contract Mismatches Summary

**Three surgical fixes aligning desktop chat, mobile realtime, and mobile guardrails with Worker request/response shapes**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-07T11:20:48Z
- **Completed:** 2026-04-07T11:22:19Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- Desktop useChat.ts sends `{ input: [...] }` matching Worker's destructuring and parses response as plain string
- Worker /api/realtime/client_secrets returns `{ client_secret: { value } }` JSON matching mobile session.ts destructuring
- Mobile guardrails.ts uses `response.json()` to correctly unwrap Worker c.json() envelope for regex classification

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix desktop useChat.ts request body and response parsing** - `43bd4bc` (fix)
2. **Task 2: Fix Worker /api/realtime/client_secrets to return JSON** - `876282f` (fix)
3. **Task 3: Fix mobile guardrails.ts response parsing** - `f3381fc` (fix)

## Files Created/Modified
- `apps/main/src/hooks/useChat.ts` - Fixed request body key (`messages` to `input`) and response type assertion (`{ message: string }` to `string`)
- `workers/worker/src/index.ts` - Changed `c.text(parsedResponse.value)` to `c.json({ client_secret: { value: parsedResponse.value } })`
- `apps/mobile/lib/realtime/guardrails.ts` - Changed `response.text()` to `response.json() as string`

## Decisions Made
- Surgical fixes only -- changed minimum lines to align contracts without refactoring surrounding code

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All three API contracts between clients and Worker are now aligned
- Desktop RAG chat, mobile realtime voice sessions, and mobile AI guardrails should function end-to-end
- Ready for feature parity testing in phases 10 and 11

## Self-Check: PASSED

- All 3 modified files exist on disk
- All 3 task commits verified in git log (43bd4bc, 876282f, f3381fc)
- SUMMARY.md created at expected path

---
*Phase: 12-fix-api-contract-mismatches*
*Completed: 2026-04-07*

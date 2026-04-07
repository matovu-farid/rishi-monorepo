---
phase: 11-mobile-feature-parity
plan: 02
subsystem: realtime-voice
tags: [webrtc, openai-realtime, react-native-webrtc, guardrails, microphone-permissions, rag]

# Dependency graph
requires:
  - phase: 06-on-device-rag-ai-conversations
    provides: "RAG pipeline (vector-store, embedder, server-fallback), Jest test infrastructure"
  - phase: 11-mobile-feature-parity plan 01
    provides: "NSMicrophoneUsageDescription in Info.plist, app permissions config"
provides:
  - "createRealtimeSession: WebRTC session lifecycle with OpenAI Realtime API"
  - "closeRealtimeSession: clean session teardown (tracks, data channel, peer connection)"
  - "checkGuardrail: tripwire classification via Worker LLM"
  - "RealtimeSessionHandle, RealtimeConfig, ServerEvent types"
  - "BOOK_CONTEXT_TOOL, END_CONVERSATION_TOOL definitions"
  - "REALTIME_AGENT_INSTRUCTIONS system prompt (ported from desktop)"
affects: [11-mobile-feature-parity plan 03]

# Tech tracking
tech-stack:
  added: [react-native-webrtc (peer dep)]
  patterns: [raw-webrtc-data-channel, tool-call-dispatch-via-dc, fail-open-guardrails]

key-files:
  created:
    - apps/mobile/lib/realtime/types.ts
    - apps/mobile/lib/realtime/session.ts
    - apps/mobile/lib/realtime/guardrails.ts
    - apps/mobile/__tests__/realtime.test.ts
    - apps/mobile/__tests__/guardrails.test.ts

key-decisions:
  - "Raw WebRTC via react-native-webrtc instead of @openai/agents (no RN support)"
  - "Android PermissionsAndroid.request for RECORD_AUDIO; iOS relies on system dialog from getUserMedia"
  - "Guardrail classification via Worker /api/text/completions endpoint, fail-open on errors"
  - "Tool call dispatch via data channel JSON messages (bookContext + endConversation)"

patterns-established:
  - "WebRTC data channel pattern: session.update -> conversation.item.create -> response.create"
  - "Tool call handling: response.function_call_arguments.done -> dispatch -> function_call_output -> response.create"
  - "Guardrail fail-open: catch all errors, return false (no tripwire) to avoid blocking audio"

requirements-completed: [PARITY-M01, PARITY-M02]

# Metrics
duration: 5min
completed: 2026-04-07
---

# Phase 11 Plan 02: Realtime Voice Session and Guardrails Summary

**OpenAI Realtime voice session via raw WebRTC with bookContext/endConversation tool dispatch, Android mic permission handling, and fail-open guardrail tripwire classification**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-07T04:17:42Z
- **Completed:** 2026-04-07T04:23:06Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- WebRTC session lifecycle: ephemeral key exchange, SDP negotiation, data channel setup with tools and system prompt
- bookContext tool executes local RAG pipeline (embed query via on-device or server fallback, then vector search) and returns results via data channel
- endConversation tool cleanly closes session (stops tracks, closes DC and PC)
- Android runtime microphone permission request before getUserMedia; iOS relies on system dialog
- Guardrail module classifies AI output as relevant/small-talk/off-topic via Worker LLM, tripwire fires only for off-topic
- 16 total tests across both modules (11 realtime + 5 guardrails), all passing

## Task Commits

Each task was committed atomically:

1. **Task 1: Realtime types, session module, tests (RED)** - `8bcadda` (test)
2. **Task 1: Realtime types, session module, tests (GREEN)** - `74515a7` (feat)
3. **Task 2: Guardrails module and tests (RED)** - `1ade95f` (test)
4. **Task 2: Guardrails module and tests (GREEN)** - `f5613a8` (feat)

## Files Created/Modified
- `apps/mobile/lib/realtime/types.ts` - RealtimeSessionHandle, RealtimeConfig, ServerEvent types, tool definitions, REALTIME_AGENT_INSTRUCTIONS prompt
- `apps/mobile/lib/realtime/session.ts` - createRealtimeSession (WebRTC lifecycle), closeRealtimeSession, handleServerEvent (tool dispatch), requestMicrophonePermission
- `apps/mobile/lib/realtime/guardrails.ts` - checkGuardrail (Worker LLM classification, fail-open)
- `apps/mobile/__tests__/realtime.test.ts` - 11 tests for session creation, tool calls, permissions
- `apps/mobile/__tests__/guardrails.test.ts` - 5 tests for classification logic and fail-open behavior

## Decisions Made
- Raw WebRTC via react-native-webrtc instead of @openai/agents SDK (no React Native support)
- Android PermissionsAndroid.request for RECORD_AUDIO; iOS relies on system dialog triggered by getUserMedia
- Guardrail classification via Worker /api/text/completions endpoint with fail-open on errors
- Tool call dispatch via data channel JSON messages matching OpenAI Realtime protocol

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Used virtual mock for react-native-webrtc in tests**
- **Found during:** Task 1 (RED phase)
- **Issue:** react-native-webrtc not installed as npm dependency (native module), jest.mock fails to resolve
- **Fix:** Added `{ virtual: true }` option to jest.mock calls for react-native-webrtc and react-native
- **Files modified:** apps/mobile/__tests__/realtime.test.ts
- **Verification:** All 11 tests pass
- **Committed in:** 74515a7 (Task 1 GREEN commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Standard test infrastructure fix for native module mocking. No scope creep.

## Issues Encountered
None beyond the mock resolution issue documented above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Realtime session module ready for UI integration in Plan 03 (voice chat screen)
- Types and handle interface defined for hook consumption
- Guardrail module integrated into session event handler

---
*Phase: 11-mobile-feature-parity*
*Completed: 2026-04-07*

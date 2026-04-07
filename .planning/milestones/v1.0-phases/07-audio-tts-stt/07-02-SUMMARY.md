---
phase: 07-audio-tts-stt
plan: 02
subsystem: audio, api
tags: [deepgram, stt, speech-to-text, expo-audio, voice-input, react-native]

# Dependency graph
requires:
  - phase: 06-on-device-rag-ai-conversations
    provides: Chat UI with ChatInput component, apiClient, BookChatScreen
provides:
  - Worker POST /api/audio/transcribe Deepgram STT proxy endpoint
  - useVoiceInput hook for record -> transcribe -> return text flow
  - VoiceMicButton component with idle/recording/transcribing states
  - ChatInput voice integration with mic button and status messages
  - apiClient support for non-JSON Content-Type (binary uploads)
affects: [08-desktop-sync]

# Tech tracking
tech-stack:
  added: [deepgram-nova-3, expo-audio-recorder]
  patterns: [binary-audio-proxy, voice-input-hook-pattern, overridable-content-type]

key-files:
  created:
    - apps/mobile/hooks/useVoiceInput.ts
    - apps/mobile/components/VoiceMicButton.tsx
    - apps/mobile/__tests__/tts/voice-input.test.ts
  modified:
    - workers/worker/src/index.ts
    - apps/mobile/components/ChatInput.tsx
    - apps/mobile/components/ui/icon-symbol.tsx
    - apps/mobile/lib/api.ts
    - apps/mobile/app/chat/[bookId].tsx

key-decisions:
  - "apiClient Content-Type default before spread: allows callers to override for binary uploads without breaking existing JSON callers"
  - "externalText prop on ChatInput: transcribed text injected from parent for user review before sending"
  - "Base64 -> Uint8Array conversion in useVoiceInput: expo-file-system reads as base64, converted to binary ArrayBuffer for Worker upload"

patterns-established:
  - "Binary upload pattern: apiClient with overridden Content-Type header for non-JSON payloads"
  - "Voice input hook pattern: useVoiceInput encapsulates permission -> record -> transcribe -> cleanup lifecycle"

requirements-completed: [AUD-04, AUD-05, AUD-06]

# Metrics
duration: 12min
completed: 2026-04-06
---

# Phase 07 Plan 02: Voice Input (STT) Summary

**Deepgram Nova-3 STT proxy on Worker with mobile voice recording, transcription, and chat input integration via expo-audio**

## Performance

- **Duration:** 12 min
- **Started:** 2026-04-06T10:14:47Z
- **Completed:** 2026-04-06T10:26:47Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- Worker /api/audio/transcribe endpoint proxies binary audio to Deepgram Nova-3 for transcription
- useVoiceInput hook manages full record -> stop -> transcribe -> return text lifecycle with permission handling
- VoiceMicButton with idle/recording (pulsing red)/transcribing (spinner) visual states
- ChatInput integration with mic button, dynamic placeholders, and error/permission messages
- apiClient fixed to allow Content-Type override for binary uploads (non-breaking change)

## Task Commits

Each task was committed atomically:

1. **Task 1: Worker Deepgram STT endpoint** - `9c7eee7` (feat)
2. **Task 2 RED: Failing voice input tests** - `0b1855a` (test)
3. **Task 2 GREEN: Voice input hook, mic button, ChatInput integration** - `7877fef` (feat)

## Files Created/Modified
- `workers/worker/src/index.ts` - Added POST /api/audio/transcribe Deepgram STT proxy route
- `apps/mobile/hooks/useVoiceInput.ts` - Voice input hook: record, transcribe, error/permission state
- `apps/mobile/components/VoiceMicButton.tsx` - Mic button with idle/recording/transcribing states and pulse animation
- `apps/mobile/components/ChatInput.tsx` - Added mic button, voice status, permission/error messages, externalText prop
- `apps/mobile/components/ui/icon-symbol.tsx` - Added mic.fill and mic.slash.fill icon mappings
- `apps/mobile/lib/api.ts` - Fixed Content-Type ordering to allow override for binary uploads
- `apps/mobile/app/chat/[bookId].tsx` - Wired useVoiceInput hook with handleMicPress handler
- `apps/mobile/__tests__/tts/voice-input.test.ts` - 4 unit tests for useVoiceInput hook

## Decisions Made
- apiClient Content-Type placed as default before spread so callers can override for binary audio without breaking existing JSON requests
- Added externalText prop to ChatInput instead of lifting text state, keeping ChatInput's internal state management intact
- Base64 -> Uint8Array conversion in hook since expo-file-system reads files as base64 but Worker expects raw binary

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added externalText prop for transcript injection**
- **Found during:** Task 2 (ChatInput integration)
- **Issue:** Plan says `setText(transcript)` but ChatInput manages its own internal text state with no way to inject text from parent
- **Fix:** Added externalText prop to ChatInput with useEffect to populate internal state when external text arrives
- **Files modified:** apps/mobile/components/ChatInput.tsx, apps/mobile/app/chat/[bookId].tsx
- **Verification:** Voice transcript flow populates input for user review
- **Committed in:** 7877fef (Task 2 GREEN commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Necessary for transcript-to-input flow. No scope creep.

## Issues Encountered
- Worker wrangler dry-run fails due to pre-existing drizzle-orm/sqlite-core resolution issue (unrelated to STT changes, existing in prior phases)
- @testing-library/react-native not available; tests use mock useState pattern consistent with existing Phase 06 test infrastructure

## User Setup Required
None - DEEPGRAM_KEY binding already exists in Worker CloudflareBindings interface (configured in prior TTS setup).

## Next Phase Readiness
- Voice input STT system complete alongside TTS from Plan 01
- Audio features (TTS + STT) fully integrated into mobile chat experience
- Ready for Phase 08 (desktop sync)

---
*Phase: 07-audio-tts-stt*
*Completed: 2026-04-06*

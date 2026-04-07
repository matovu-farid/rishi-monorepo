---
phase: 07-audio-tts-stt
plan: 01
subsystem: audio
tags: [tts, expo-audio, text-to-speech, openai-tts, sqlite, react-native]

requires:
  - phase: 06-on-device-rag-ai-conversations
    provides: "SQLite chunks table, rawDb singleton, apiClient, chunker"
provides:
  - "TTSQueue: chunk queue manager fetching from SQLite, requesting audio from Worker /api/audio/speech"
  - "TTSPlayer: expo-audio wrapper with play/pause/stop/resume and playback finished callback"
  - "useTTSPlayer: React hook orchestrating queue + player with auto-advance"
  - "TTSControls: floating bottom bar with play/pause/stop/skip and chunk progress"
  - "ReaderToolbar TTS button: speaker icon toggles TTS on/off"
affects: [07-audio-tts-stt, reader]

tech-stack:
  added: [expo-audio]
  patterns: [createAudioPlayer non-React API, TTS chunk queue with prefetch, base64 mp3 file caching]

key-files:
  created:
    - apps/mobile/lib/tts/tts-queue.ts
    - apps/mobile/lib/tts/tts-player.ts
    - apps/mobile/hooks/useTTSPlayer.ts
    - apps/mobile/components/TTSControls.tsx
    - apps/mobile/__tests__/tts/tts-queue.test.ts
    - apps/mobile/__tests__/tts/tts-player.test.ts
  modified:
    - apps/mobile/components/ReaderToolbar.tsx
    - apps/mobile/components/ui/icon-symbol.tsx
    - apps/mobile/app/reader/[id].tsx

key-decisions:
  - "Used createAudioPlayer (non-React API) for TTSPlayer class since it runs outside React component context"
  - "Base64 encoding for writing mp3 to FileSystem.cacheDirectory (expo-file-system requires base64 for binary writes)"
  - "Prefetch next 2 chunks in background after current chunk starts playing for seamless transitions"
  - "Disabled toolbar auto-hide when TTS is active so user can access stop button"

patterns-established:
  - "TTS chunk queue with SQLite-backed chunk list and audio cache map"
  - "Non-React audio player class with createAudioPlayer from expo-audio"
  - "Hook-based orchestration of queue + player instances via useRef"

requirements-completed: [AUD-01, AUD-02, AUD-03]

duration: 11min
completed: 2026-04-06
---

# Phase 7 Plan 1: TTS Playback System Summary

**TTS playback system: SQLite chunk queue, expo-audio player, floating controls bar, and reader toolbar integration for sequential book read-aloud**

## Performance

- **Duration:** 11 min
- **Started:** 2026-04-06T10:14:32Z
- **Completed:** 2026-04-06T10:25:32Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- TTS queue service reads chunks from SQLite ordered by chunk_index, requests mp3 audio from Worker /api/audio/speech, caches to temp files
- Audio player wraps expo-audio createAudioPlayer with play/pause/stop/resume and auto-advance on playback finished
- Floating TTSControls bar with play/pause/stop/skip buttons, animated entrance, and chunk progress indicator
- Speaker icon in reader toolbar toggles TTS on/off with active state tinting
- 13 unit tests covering queue operations and player state transitions

## Task Commits

Each task was committed atomically:

1. **Task 1: TTS queue service, player wrapper, and tests** - `68467d8` (feat, TDD)
2. **Task 2: TTS React hook, UI components, and reader integration** - `2ef1fde` (feat)

## Files Created/Modified
- `apps/mobile/lib/tts/tts-queue.ts` - TTSQueue class: chunk fetching, ensureBookChunked, requestTTSAudio, prefetchNext
- `apps/mobile/lib/tts/tts-player.ts` - TTSPlayer class: expo-audio wrapper with status tracking
- `apps/mobile/hooks/useTTSPlayer.ts` - React hook orchestrating queue + player with auto-advance and cleanup
- `apps/mobile/components/TTSControls.tsx` - Floating bottom bar with play/pause/stop/skip and progress bar
- `apps/mobile/__tests__/tts/tts-queue.test.ts` - 8 tests for queue operations
- `apps/mobile/__tests__/tts/tts-player.test.ts` - 5 tests for player state transitions
- `apps/mobile/components/ReaderToolbar.tsx` - Added onTTSPress and ttsActive props with speaker icon
- `apps/mobile/components/ui/icon-symbol.tsx` - Added speaker, backward, forward, pause, play icon mappings
- `apps/mobile/app/reader/[id].tsx` - Integrated useTTSPlayer hook and TTSControls rendering

## Decisions Made
- Used createAudioPlayer (non-React API) for TTSPlayer class since it runs outside React component context
- Base64 encoding for writing mp3 to FileSystem.cacheDirectory (expo-file-system requires base64 for binary writes)
- Prefetch next 2 chunks in background after current chunk starts playing
- Disabled toolbar auto-hide when TTS is active so user can access stop button
- Audio cache cleanup: delete previously played chunks (2 back) to manage disk usage

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- TTS playback complete, ready for STT voice input (Plan 2)
- Worker /api/audio/speech endpoint already exists and is used by TTS queue

---
*Phase: 07-audio-tts-stt*
*Completed: 2026-04-06*

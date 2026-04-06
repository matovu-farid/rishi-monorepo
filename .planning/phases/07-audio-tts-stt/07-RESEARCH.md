# Phase 7: Audio (TTS & STT) - Research

**Researched:** 2026-04-06
**Domain:** Audio playback, text-to-speech, speech-to-text, Cloudflare Worker proxy
**Confidence:** HIGH

## Summary

This phase adds two audio capabilities to the mobile app: (1) text-to-speech playback of book content via the existing Worker `/api/audio/speech` endpoint (OpenAI TTS), and (2) voice-based question input via a new Worker `/api/audio/transcribe` endpoint that proxies to Deepgram's pre-recorded STT API. The Worker already has a `DEEPGRAM_KEY` binding but no STT route yet.

The mobile app uses Expo SDK 54. The correct audio library is **expo-audio** (not expo-av, which is deprecated in SDK 54 and removed in SDK 55). expo-audio provides `useAudioPlayer` for playback from URLs, `useAudioRecorder` for microphone recording, and hooks for status monitoring. The existing RAG chunks table already stores sequential book text (by `chunk_index`), which serves as the TTS text source -- no new text extraction is needed.

**Primary recommendation:** Use expo-audio for both playback and recording. Build a TTS queue service (inspired by the desktop TTSQueue pattern) that fetches sequential chunks, requests audio from the Worker, and manages playback. Build the Deepgram STT Worker endpoint as a simple proxy that accepts binary audio and returns transcription text. Add a microphone button to the existing ChatInput component.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| AUD-01 | User can listen to book text via TTS (Worker /api/audio/speech endpoint) | expo-audio useAudioPlayer plays from URLs; Worker endpoint already exists returning mp3 audio; chunks table provides sequential text |
| AUD-02 | TTS playback has play/pause/stop controls | expo-audio player.play()/pause() methods; useAudioPlayerStatus hook for state tracking |
| AUD-03 | TTS reads sequentially through book content with queue management | chunks table ordered by chunk_index provides sequential text; queue prefetches next chunks |
| AUD-04 | User can ask voice questions via speech input | expo-audio useAudioRecorder captures audio; recording URI provides file for upload |
| AUD-05 | Voice input transcribed via Worker Deepgram STT endpoint | New Worker route proxies to Deepgram pre-recorded API; returns transcript text |
| AUD-06 | Worker Deepgram STT endpoint created for transcription | Hono route accepting binary audio, forwarding to Deepgram `https://api.deepgram.com/v1/listen`, DEEPGRAM_KEY binding already exists |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| expo-audio | ~55.0.x (Expo 54 compatible) | Audio playback and recording | Official Expo audio library; expo-av deprecated in SDK 54 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| expo-file-system | ~19.0.x (already installed) | Access recorded audio file for upload | Reading recording URI to send as binary |

### No New Worker Dependencies
The Worker already has `openai` (for TTS) and the `DEEPGRAM_KEY` binding. The Deepgram STT call is a simple `fetch` to their REST API -- no SDK needed.

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| expo-audio | react-native-track-player | Track player is heavier, designed for music apps with background playback; expo-audio simpler for TTS chunks |
| Deepgram pre-recorded | Deepgram live/streaming | Live streaming is v2 scope (AUD-V2-01); pre-recorded is simpler for v1 |
| Worker proxy for Deepgram | Direct Deepgram call from mobile | Leaks API key to client; Worker proxy keeps key server-side |

**Installation:**
```bash
cd apps/mobile && npx expo install expo-audio
```

## Architecture Patterns

### Recommended Project Structure
```
apps/mobile/
  lib/
    tts/
      tts-queue.ts        # Queue manager: fetches chunks, requests TTS, manages sequence
      tts-player.ts       # Wraps expo-audio player with play/pause/stop/next
    audio-recording.ts    # Record audio, get URI, upload for STT
  hooks/
    useTTSPlayer.ts       # React hook exposing TTS controls + state
    useVoiceInput.ts      # React hook for record -> transcribe -> return text
  components/
    TTSControls.tsx       # Floating play/pause/stop/skip UI for reader
    VoiceMicButton.tsx    # Mic button for ChatInput (press-and-hold or toggle)
workers/worker/
  src/
    index.ts              # Add /api/audio/transcribe route (or in routes/audio.ts)
```

### Pattern 1: TTS Queue with Chunk Prefetch
**What:** A service that reads sequential chunks from the local SQLite chunks table, requests TTS audio from the Worker for each chunk, and plays them in order. Prefetches the next 2-3 chunks while the current one plays.
**When to use:** For AUD-01, AUD-02, AUD-03.
**Example:**
```typescript
// Source: Based on desktop TTSQueue pattern adapted for expo-audio
import { createAudioPlayer } from 'expo-audio'
import { rawDb } from '@/lib/db'
import { apiClient } from '@/lib/api'

interface TTSState {
  status: 'idle' | 'playing' | 'paused' | 'loading'
  currentChunkIndex: number
  totalChunks: number
}

function getBookChunksOrdered(bookId: string): Array<{ id: string; text: string; chunkIndex: number }> {
  return rawDb.getAllSync(
    'SELECT id, text, chunk_index as chunkIndex FROM chunks WHERE book_id = ? ORDER BY chunk_index ASC',
    [bookId]
  ) as any
}

async function requestTTSAudio(text: string): Promise<string> {
  const response = await apiClient('/api/audio/speech', {
    method: 'POST',
    body: JSON.stringify({
      voice: 'alloy',
      input: text,
      response_format: 'mp3',
      speed: 1.0,
    }),
  })
  if (!response.ok) throw new Error(`TTS failed: ${response.status}`)
  // Write audio blob to temp file and return URI
  // expo-audio can also play from a URL directly if we return the response
  const blob = await response.blob()
  // ... write to FileSystem.cacheDirectory and return URI
  return audioUri
}
```

### Pattern 2: Voice Input (Record -> Transcribe -> Text)
**What:** Record audio via expo-audio's `useAudioRecorder`, upload the recording to the Worker STT endpoint, receive transcription text, and feed it into the existing RAG query pipeline.
**When to use:** For AUD-04, AUD-05.
**Example:**
```typescript
// Source: expo-audio docs + Deepgram REST API
import { useAudioRecorder, RecordingPresets } from 'expo-audio'
import * as FileSystem from 'expo-file-system'
import { apiClient } from '@/lib/api'

function useVoiceInput() {
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY)

  const startRecording = async () => {
    await recorder.prepareToRecordAsync()
    recorder.record()
  }

  const stopAndTranscribe = async (): Promise<string> => {
    await recorder.stop()
    const uri = recorder.uri
    if (!uri) throw new Error('No recording URI')

    // Read recording as base64 and send to Worker
    const base64 = await FileSystem.readAsStringAsync(uri, {
      encoding: FileSystem.EncodingType.Base64,
    })

    const response = await apiClient('/api/audio/transcribe', {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream' },
      body: base64, // Worker decodes base64 -> binary -> Deepgram
    })

    const result = await response.json()
    return result.transcript
  }

  return { startRecording, stopAndTranscribe, isRecording: recorder.isRecording }
}
```

### Pattern 3: Worker Deepgram STT Proxy
**What:** A new Hono POST route on the Worker that receives audio binary, forwards it to Deepgram's pre-recorded STT API, and returns the transcript.
**When to use:** For AUD-06.
**Example:**
```typescript
// Source: Deepgram pre-recorded API docs
app.post("/api/audio/transcribe", requireWorkerAuth, async (c) => {
  const audioData = await c.req.arrayBuffer()

  const response = await fetch(
    "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&language=en",
    {
      method: "POST",
      headers: {
        "Authorization": `Token ${c.env.DEEPGRAM_KEY}`,
        "Content-Type": "audio/webm", // or detect from request
      },
      body: audioData,
    }
  )

  if (!response.ok) {
    const error = await response.text()
    return c.json({ error: `Deepgram error: ${response.status}` }, 500)
  }

  const result = await response.json()
  const transcript = result.results?.channels?.[0]?.alternatives?>[0]?.transcript || ""
  return c.json({ transcript })
})
```

### Anti-Patterns to Avoid
- **Playing TTS from blob URLs in memory:** Do not try to play audio directly from fetch response blobs. Write to a temp file first, then play via expo-audio's file URI source. Expo-audio expects file URIs or remote URLs, not in-memory blobs.
- **Sending API key from mobile to Deepgram directly:** Always proxy through the Worker. The DEEPGRAM_KEY must stay server-side.
- **Re-extracting book text for TTS:** The chunks table already has sequential text from the RAG pipeline. Query it ordered by chunk_index instead of re-parsing the EPUB.
- **Using expo-av:** It is deprecated in SDK 54. Use expo-audio instead.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Audio playback | Custom native audio module | expo-audio `useAudioPlayer` | Handles codec support, platform differences, lifecycle |
| Audio recording | Direct mic access | expo-audio `useAudioRecorder` | Handles permissions, encoding presets, file output |
| STT transcription | On-device Whisper model | Deepgram REST API via Worker | Accuracy, speed, no 200MB model download; v1 is network-dependent anyway |
| TTS synthesis | On-device TTS | OpenAI TTS API via Worker | Quality of OpenAI voices far exceeds on-device TTS |
| Audio file caching | Custom file cache | FileSystem.cacheDirectory | OS manages cleanup, no manual eviction needed for v1 |

**Key insight:** The desktop app uses a complex queue with priority system, caching, and retry logic. For mobile v1, simplify significantly: a linear queue through chunks (no priority), cache in FileSystem.cacheDirectory (auto-cleaned by OS), simple retry on failure. The desktop pattern is a reference, not a blueprint.

## Common Pitfalls

### Pitfall 1: expo-audio Not Installed as Expo Module
**What goes wrong:** Installing expo-audio with `npm install` instead of `npx expo install` can result in version incompatibility with SDK 54.
**Why it happens:** expo-audio version must match the Expo SDK version exactly.
**How to avoid:** Always use `npx expo install expo-audio`.
**Warning signs:** Build errors mentioning native module version mismatch.

### Pitfall 2: Content-Type Mismatch on apiClient for Binary Audio
**What goes wrong:** The mobile `apiClient` hardcodes `Content-Type: application/json`. Sending binary audio for STT will fail.
**Why it happens:** apiClient was designed for JSON APIs only.
**How to avoid:** Either modify apiClient to accept custom Content-Type, or create a separate `apiClientRaw` function for binary uploads that does not set Content-Type to application/json.
**Warning signs:** 400 errors from the Worker or garbled audio on the Deepgram side.

### Pitfall 3: TTS Audio Temp Files Accumulating
**What goes wrong:** Each TTS chunk creates a temp audio file. Without cleanup, storage grows unbounded.
**Why it happens:** Writing audio responses to FileSystem.cacheDirectory but never deleting after playback.
**How to avoid:** Delete temp audio files after the player finishes playing them. The `didJustFinish` status from useAudioPlayerStatus is the signal.
**Warning signs:** App storage growing by 50-100MB per hour of TTS use.

### Pitfall 4: Recording Permissions Not Requested
**What goes wrong:** Audio recording fails silently or crashes.
**Why it happens:** expo-audio requires explicit permission grant for microphone access.
**How to avoid:** Call `Audio.requestPermissionsAsync()` before first recording attempt. Show permission rationale UI.
**Warning signs:** Recording URI is null after stop.

### Pitfall 5: Chunks Not Available for Books Without Embeddings
**What goes wrong:** TTS fails because the chunks table is empty for a book that was never embedded.
**Why it happens:** Chunking and embedding happen together in the RAG pipeline. If a user skips the chat screen, the book may never be chunked.
**How to avoid:** Separate chunking from embedding. Run chunking on TTS start if chunks don't exist. Or reuse the existing `getChunks` from the chunker to chunk on-demand.
**Warning signs:** Empty chunk query results when starting TTS.

### Pitfall 6: Large Chunk Text Exceeding TTS API Limits
**What goes wrong:** OpenAI TTS API has a 4096-character limit per request.
**Why it happens:** Some chunks may be close to 500 chars (the max chunk size from chunker), which is fine, but if the chunker is ever adjusted upward, it could exceed limits.
**How to avoid:** Cap TTS input at 4096 characters. The current 500-char chunks are well within limits.
**Warning signs:** 400 errors from the Worker TTS endpoint.

## Code Examples

### Querying Chunks for TTS (Sequential Book Text)
```typescript
// Source: Existing vector-store.ts pattern + rawDb usage
import { rawDb } from '@/lib/db'

export function getBookChunksForTTS(
  bookId: string
): Array<{ id: string; text: string; chunkIndex: number; chapter: string | null }> {
  return rawDb.getAllSync(
    'SELECT id, text, chunk_index as chunkIndex, chapter FROM chunks WHERE book_id = ? ORDER BY chunk_index ASC',
    [bookId]
  ) as any
}

export function getChunkCount(bookId: string): number {
  const result = rawDb.getFirstSync(
    'SELECT COUNT(*) as count FROM chunks WHERE book_id = ?',
    [bookId]
  ) as any
  return result?.count ?? 0
}
```

### expo-audio Player with Status Tracking
```typescript
// Source: expo-audio official docs
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio'

function useTTSPlayback(audioUri: string | null) {
  const player = useAudioPlayer(audioUri)
  const status = useAudioPlayerStatus(player)

  return {
    play: () => player.play(),
    pause: () => player.pause(),
    isPlaying: status.playing,
    isBuffering: status.isBuffering,
    didFinish: status.didJustFinish,
    currentTime: status.currentTime,
    duration: status.duration,
  }
}
```

### Writing TTS Audio Response to Temp File
```typescript
// Source: expo-file-system docs + fetch pattern
import * as FileSystem from 'expo-file-system'

async function saveTTSAudioToTemp(response: Response, chunkId: string): Promise<string> {
  const arrayBuffer = await response.arrayBuffer()
  const base64 = btoa(String.fromCharCode(...new Uint8Array(arrayBuffer)))
  const uri = `${FileSystem.cacheDirectory}tts-${chunkId}.mp3`
  await FileSystem.writeAsStringAsync(uri, base64, {
    encoding: FileSystem.EncodingType.Base64,
  })
  return uri
}
```

### Worker STT Route (Complete)
```typescript
// Source: Deepgram pre-recorded API docs
app.post("/api/audio/transcribe", requireWorkerAuth, async (c) => {
  const contentType = c.req.header("Content-Type") || "audio/webm"
  const audioData = await c.req.arrayBuffer()

  if (audioData.byteLength === 0) {
    return c.json({ error: "Empty audio data" }, 400)
  }

  const dgResponse = await fetch(
    "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&punctuate=true&language=en",
    {
      method: "POST",
      headers: {
        "Authorization": `Token ${c.env.DEEPGRAM_KEY}`,
        "Content-Type": contentType,
      },
      body: audioData,
    }
  )

  if (!dgResponse.ok) {
    const errorText = await dgResponse.text()
    console.error("Deepgram error:", dgResponse.status, errorText)
    return c.json({ error: "Transcription failed" }, 502)
  }

  const result = await dgResponse.json() as any
  const transcript =
    result?.results?.channels?.[0]?.alternatives?.[0]?.transcript || ""

  return c.json({ transcript })
})
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| expo-av for audio | expo-audio | Expo SDK 54 (deprecated), SDK 55 (removed) | Must use expo-audio; expo-av will not receive patches |
| Deepgram Nova-2 | Deepgram Nova-3 | 2025 | Better accuracy (5.26% WER English); use `model=nova-3` |
| OpenAI TTS | OpenAI TTS (tts-1) | Stable | No change needed; Worker already uses tts-1 |

**Deprecated/outdated:**
- expo-av: Deprecated in SDK 54, removed in SDK 55. Do not use.
- Deepgram Nova-2: Still works but Nova-3 is recommended for better accuracy.

## Open Questions

1. **Audio format from expo-audio recorder**
   - What we know: expo-audio records with configurable presets (HIGH_QUALITY, etc.). Output format depends on platform (m4a on iOS, webm on Android).
   - What's unclear: Exact Content-Type to send to Deepgram for each platform.
   - Recommendation: Detect platform, set Content-Type accordingly (audio/m4a for iOS, audio/webm for Android). Deepgram supports both.

2. **Chunking on TTS start for non-embedded books**
   - What we know: Chunks exist only for books that went through the RAG embedding pipeline.
   - What's unclear: Whether we should separate chunking from embedding, or require embedding before TTS.
   - Recommendation: Add a `ensureBookChunked` function that runs only the text extraction + chunking step (without embedding) if chunks don't exist. This is fast (~1-2 seconds) and avoids coupling TTS to the embedding model.

3. **TTS playback continuation across reader page turns**
   - What we know: Desktop Player subscribes to page change events. Mobile EPUB reader uses @epubjs-react-native.
   - What's unclear: Whether the mobile reader emits events usable for sync.
   - Recommendation: TTS reads from the chunks table sequentially (independent of reader page). The reader's current page is not the TTS source -- chunks are. This decouples TTS from reader navigation, which is simpler and more reliable.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Jest 30.x + ts-jest 29.x |
| Config file | `apps/mobile/jest.config.js` |
| Quick run command | `cd apps/mobile && npx jest --testPathPattern=__tests__/tts` |
| Full suite command | `cd apps/mobile && npx jest` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUD-01 | TTS fetches chunk text and requests audio from Worker | unit | `cd apps/mobile && npx jest __tests__/tts/tts-queue.test.ts -x` | Wave 0 |
| AUD-02 | Play/pause/stop state transitions | unit | `cd apps/mobile && npx jest __tests__/tts/tts-player.test.ts -x` | Wave 0 |
| AUD-03 | Sequential chunk iteration and queue advance | unit | `cd apps/mobile && npx jest __tests__/tts/tts-queue.test.ts -x` | Wave 0 |
| AUD-04 | Voice recording produces file URI | manual-only | N/A (requires device microphone) | N/A |
| AUD-05 | Transcription request returns text | unit | `cd apps/mobile && npx jest __tests__/tts/voice-input.test.ts -x` | Wave 0 |
| AUD-06 | Worker STT endpoint proxies to Deepgram | manual-only | curl test against deployed Worker | N/A |

### Sampling Rate
- **Per task commit:** `cd apps/mobile && npx jest --testPathPattern=__tests__/tts`
- **Per wave merge:** `cd apps/mobile && npx jest`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `apps/mobile/__tests__/tts/tts-queue.test.ts` -- covers AUD-01, AUD-03
- [ ] `apps/mobile/__tests__/tts/tts-player.test.ts` -- covers AUD-02
- [ ] `apps/mobile/__tests__/tts/voice-input.test.ts` -- covers AUD-05

## Sources

### Primary (HIGH confidence)
- [expo-audio official docs (Expo SDK 54)](https://docs.expo.dev/versions/v54.0.0/sdk/audio/) -- API reference, useAudioPlayer, useAudioRecorder, code examples
- [Deepgram pre-recorded STT API reference](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded) -- endpoint URL, auth, request/response format
- Existing codebase: `workers/worker/src/index.ts` line 197 -- Worker /api/audio/speech endpoint (OpenAI TTS proxy)
- Existing codebase: `apps/main/src/modules/ttsQueue.ts` -- Desktop TTS queue pattern (reference implementation)
- Existing codebase: `apps/mobile/lib/rag/chunker.ts` -- Text extraction and chunking logic
- Existing codebase: `apps/mobile/lib/rag/vector-store.ts` -- chunks SQLite table schema

### Secondary (MEDIUM confidence)
- [Deepgram getting started docs](https://developers.deepgram.com/docs/pre-recorded-audio) -- curl examples with binary audio upload
- [expo-av deprecation notice](https://github.com/expo/expo/issues/37259) -- confirmed expo-av removed in SDK 55

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- expo-audio is the official Expo audio library; Deepgram REST API is well-documented
- Architecture: HIGH -- follows existing codebase patterns (rawDb, apiClient, chunks table); desktop TTS implementation serves as proven reference
- Pitfalls: HIGH -- based on direct codebase analysis (apiClient Content-Type issue, chunks dependency)

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (30 days -- stable domain)

# Modular Voice Pipeline Design

## Overview

A modular voice chat pipeline that replaces the OpenAI Realtime API with a composable STT -> LLM -> TTS chain. Local TTS (Kokoro) and VAD (Silero) run on-device. STT (OpenAI Whisper) and LLM (gpt-4o-mini) run via the existing Cloudflare Worker proxy. The pipeline is a drop-in replacement for the current realtime chat, togglable in settings.

## Motivation

- **Latency**: Local TTS eliminates network round-trip on speech output. Streaming LLM tokens into sentence-level TTS synthesis creates a pipelining effect that can beat the OpenAI Realtime API's end-to-end latency (estimated 500-900ms vs 800-1500ms).
- **Cost control**: Local TTS has zero per-character cost. Heavy users don't scale API spend on speech synthesis.
- **Modularity**: Each stage (VAD, STT, LLM, TTS) has a trait abstraction. Any stage can be swapped to a local model when open-source quality improves — particularly STT, where models like Parakeet TDT 0.6B already show competitive accuracy on African English accents (~21% WER).
- **Debuggability**: Unlike the Realtime API black box, each stage produces inspectable intermediate output (audio -> transcript -> LLM response -> synthesized speech).
- **Offline TTS**: Speech synthesis works without network access. If LLM/STT move local later, the entire pipeline becomes fully offline.

## Architecture

```
Frontend (React)
  +--------------+    +---------------+
  | AIChatOrb    |    | chatStore     |
  | (UI only)    |--->| (state mgmt)  |
  +--------------+    +-------+-------+
                              | Tauri IPC events
------------------------------|----------------------------
Rust Backend                  |
  +---------------------------v----------------------------+
  |          VoicePipeline (orchestrator)                   |
  |                                                        |
  |  +---------+   +---------+   +------------------+     |
  |  | Mic +   |-->|  STT    |-->| LLM (gpt-4o-mini |     |
  |  |  VAD    |   |(Whisper |   | + book context)  |     |
  |  |(cpal +  |   |via wrkr)|   +--------+---------+     |
  |  |silero)  |   +---------+            |               |
  |  +---------+                          v               |
  |                               +-------------+         |
  |                               |  TTS (Kokoro |         |
  |                               |  local model)|         |
  |                               +------+------+         |
  |                                      |                |
  |                               +------v------+         |
  |                               | Audio Out   |         |
  |                               | (cpal)      |         |
  |                               +-------------+         |
  +--------------------------------------------------------+
```

## Pipeline Stages

### Stage 1: VAD (Local)

- **Model**: Silero VAD (~2MB ONNX)
- **Purpose**: Detect when the user starts and stops speaking
- **Behavior**: Mic stays open during `listening` state. VAD monitors audio frames. When speech ends (configurable silence threshold), the captured audio chunk is forwarded to STT.
- **Interruption**: If VAD detects speech during `speaking` state, immediately stop Kokoro playback, cancel pending TTS queue, transition to `listening`.

### Stage 2: STT (Worker)

- **Provider**: OpenAI Whisper via worker endpoint
- **Endpoint**: `POST /api/audio/transcribe/whisper`
- **Input**: Raw audio bytes (WAV format) from the captured speech segment
- **Output**: Transcribed text string
- **Swappability**: `SpeechToText` trait. Future local impl could use Parakeet TDT 0.6B (~600MB) via `parakeet-rs` for better African accent support.

### Stage 3: LLM (Worker)

- **Provider**: OpenAI gpt-4o-mini via worker endpoint
- **Endpoint**: `POST /api/text/completions/stream` (SSE)
- **Input**: Conversation messages array with system prompt + book context (retrieved from local vector DB via existing `get_context_for_query`)
- **Output**: Streaming text tokens via SSE
- **System prompt**: Same educational assistant prompt as the current realtime agent — adapted for text completion (no voice-specific instructions).
- **Swappability**: `ChatModel` trait. Future local impl could use Phi-3.5-mini (3.8B, ~2.4GB Q4_K_M) via `llama-cpp-rs`.

### Stage 4: TTS (Local)

- **Model**: Kokoro (~300MB, ONNX)
- **Crate**: `kokoro-rs`
- **Voice**: Default voice (af_heart), configurable later
- **Sentence pipelining**: LLM tokens are buffered until a sentence boundary (`.` `?` `!` or newline). Each complete sentence is immediately synthesized by Kokoro and queued for playback. Synthesis of sentence N+1 overlaps with playback of sentence N.
- **Audio output**: PCM audio played via `cpal` output device.

## State Machine (XState / statig)

```
idle
  |-- START --> initializing

initializing
  |-- MODELS_READY --> listening
  |-- MODELS_MISSING --> downloading

downloading
  |-- DOWNLOAD_COMPLETE --> listening
  |-- DOWNLOAD_ERROR --> error

listening
  |-- SPEECH_END --> processingSTT
  |-- STOP --> idle

processingSTT
  |-- TRANSCRIPT_READY --> processingLLM
  |-- STT_ERROR --> error

processingLLM
  |-- FIRST_SENTENCE --> speaking
  |-- LLM_ERROR --> error

speaking
  |-- PLAYBACK_COMPLETE --> listening
  |-- INTERRUPTED --> listening
  |-- STOP --> idle

error
  |-- RETRY --> listening
  |-- STOP --> idle
```

The authoritative machine runs on the Rust side using `statig`. The frontend has a mirror XState machine that subscribes to `voice-pipeline:state` Tauri events — purely for UI state (orb animation, transcript display). No logic duplication.

## Model Management

### Storage

```
$APPLOCALDATA/
  models/
    kokoro-v1.0/
      model.onnx
      voices/
        af_heart.bin
    silero-vad.onnx
```

### Download Flow

1. User taps chat orb -> `start_voice_chat` command
2. Rust checks if models exist on disk
3. If missing, emits `voice-pipeline:download-progress` events
4. Frontend shows progress bar overlay on orb
5. Downloads from HuggingFace Hub via `hf-hub` crate (same pattern as `embed_anything`)
6. On completion, pipeline starts normally
7. Subsequent launches skip download

### Memory Management

- Models are memory-mapped via ONNX Runtime — OS manages pages in/out of RAM
- When chat ends, model handles are dropped, OS reclaims memory
- No manual memory management needed

### User Controls

- Settings toggle: "Delete voice models" button, removes `models/` directory (~302MB)
- Shows current model size on disk
- Next chat session triggers re-download

## Rust Module Structure

```
apps/main/src-tauri/src/
  voice_pipeline/
    mod.rs              # Module exports, VoicePipeline struct
    machine.rs          # State machine (statig)
    vad.rs              # Silero VAD wrapper (ONNX runtime)
    stt.rs              # SpeechToText trait + Whisper-via-worker impl
    llm.rs              # ChatModel trait + gpt-4o-mini-via-worker impl
    tts.rs              # TextToSpeech trait + Kokoro impl
    audio_capture.rs    # Mic input via cpal
    audio_playback.rs   # Speaker output via cpal, sentence queue
    model_manager.rs    # Download, verify, delete models (hf-hub)
    streaming.rs        # Sentence buffer, LLM token -> TTS pipeline
```

### Trait Abstractions

```rust
trait SpeechToText: Send + Sync {
    async fn transcribe(&self, audio: &[f32], sample_rate: u32) -> Result<String>;
}

trait ChatModel: Send + Sync {
    fn complete_streaming(
        &self,
        messages: Vec<Message>,
        on_token: Box<dyn Fn(String) + Send>,
    ) -> Result<()>;
}

trait TextToSpeech: Send + Sync {
    fn synthesize(&self, text: &str) -> Result<Vec<f32>>;
}
```

### New Cargo Dependencies

| Crate | Purpose |
|-------|---------|
| `ort` | ONNX Runtime (Kokoro + Silero VAD) |
| `hf-hub` | Download models from HuggingFace |
| `statig` | State machine |
| `kokoro-rs` | Kokoro TTS bindings |

### Tauri Commands

```rust
#[tauri::command]
fn start_voice_chat(book_id: i64) -> Result<()>;

#[tauri::command]
fn stop_voice_chat() -> Result<()>;

#[tauri::command]
fn get_voice_model_status() -> Result<ModelStatus>;

#[tauri::command]
fn delete_voice_models() -> Result<()>;
```

## Worker Endpoints

### New: Whisper STT

```
POST /api/audio/transcribe/whisper
Content-Type: audio/wav
Authorization: Bearer <jwt>
Body: raw audio bytes

Response: { "text": "transcribed text" }
```

Calls OpenAI Whisper API. Keeps existing Deepgram endpoint (`/api/audio/transcribe`) untouched for text chat voice input.

### New: Streaming Chat Completion

```
POST /api/text/completions/stream
Content-Type: application/json
Authorization: Bearer <jwt>
Body: { "messages": [...], "model": "gpt-4o-mini" }

Response: SSE stream of tokens
```

Rust reads the SSE stream, buffers tokens into sentences, feeds them to Kokoro.

Both endpoints reuse the existing `OPENAI_API_KEY` worker binding and `requireWorkerAuth` middleware.

## Frontend Integration

### chatStore Changes

```typescript
interface ChatState {
  isChatting: boolean;
  pipelineMode: 'openai-realtime' | 'modular'; // default: 'modular' on feature branch
  pipelineState: 'idle' | 'initializing' | 'downloading' | 'listening'
    | 'processingSTT' | 'processingLLM' | 'speaking' | 'error';
  downloadProgress: number | null;
  transcripts: { role: 'user' | 'assistant'; text: string }[];

  startChat: (bookId: number) => void;
  stopConversation: () => void;
  setPipelineMode: (mode: 'openai-realtime' | 'modular') => void;
}
```

`startChat` checks `pipelineMode`: if `'modular'`, calls `start_voice_chat` (Rust command) instead of `startRealtime`.

### Frontend State Mirror

Lightweight XState machine subscribes to `voice-pipeline:state` Tauri events and updates `pipelineState`. Drives:
- **AIChatOrb**: Different animation per state (listening = gentle pulse, thinking = fast pulse, speaking = waveform bars)
- **Download overlay**: Shown during `downloading` state with progress bar
- **Transcript display**: `voice-pipeline:transcript` events append to `transcripts[]`

### Events from Rust

| Event | Payload | Purpose |
|-------|---------|---------|
| `voice-pipeline:state` | `{ state: string }` | Orb animation |
| `voice-pipeline:transcript` | `{ role: string, text: string }` | Chat history |
| `voice-pipeline:download-progress` | `{ percent: number, model: string }` | Download UI |
| `voice-pipeline:error` | `{ message: string }` | Error display |

### Settings UI

- Toggle: "Voice Chat Engine: OpenAI Realtime / Modular (Local TTS)"
- "Delete voice models" button (visible when models downloaded)
- Model size on disk display

### No Changes Needed

- `AIChatOrb.tsx` — responds to `isChatting` / `pipelineState` as before
- `playerMachine.ts` — still receives `CHAT_STARTED` for mutual exclusion
- Worker auth — reuses existing JWT/dev-bypass patterns

## Latency Comparison

| Pipeline | Estimated First-Word Latency |
|----------|------------------------------|
| OpenAI Realtime API | 800-1500ms |
| Modular pipeline | 500-900ms |
| Modular (optimistic, streaming TTS) | 350-600ms |

The latency advantage comes from: local TTS (no audio download), local VAD (no silence upload), text-only return path (low bandwidth), and sentence-level TTS pipelining.

## Future Swaps

Each trait abstraction enables independent upgrades:

| Stage | Current | Future Local Option |
|-------|---------|---------------------|
| STT | OpenAI Whisper (worker) | Parakeet TDT 0.6B (~600MB) |
| LLM | gpt-4o-mini (worker) | Phi-3.5-mini Q4_K_M (~2.4GB) |
| TTS | Kokoro (local) | Already local |
| VAD | Silero (local) | Already local |

Adding a local impl means implementing the trait — no pipeline changes needed.

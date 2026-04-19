# Modular Voice Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a modular voice chat pipeline (VAD + STT + LLM + TTS) as a drop-in replacement for the OpenAI Realtime API, with local Kokoro TTS and Silero VAD, and worker-based STT/LLM.

**Architecture:** Rust-native pipeline orchestrated by a `statig` state machine. Mic capture and audio playback via `cpal`. Silero VAD detects speech boundaries locally. Audio is sent to the worker for Whisper STT, then transcript + book context goes to gpt-4o-mini for LLM response (streamed via SSE). Response text is synthesized locally by Kokoro TTS with sentence-level pipelining. Frontend mirrors state via Tauri events and XState.

**Tech Stack:** Rust (statig, cpal, ort, kokoro-rs, hf-hub, reqwest), TypeScript (XState, Zustand), Cloudflare Worker (Hono, OpenAI SDK)

**Spec:** `docs/superpowers/specs/2026-04-19-modular-voice-pipeline-design.md`

---

## File Structure

### Rust (new files)

| File | Responsibility |
|------|---------------|
| `apps/main/src-tauri/src/voice_pipeline/mod.rs` | Module exports, `VoicePipeline` struct, Tauri commands |
| `apps/main/src-tauri/src/voice_pipeline/machine.rs` | `statig` state machine with all states and transitions |
| `apps/main/src-tauri/src/voice_pipeline/vad.rs` | Silero VAD ONNX wrapper — detect speech start/end |
| `apps/main/src-tauri/src/voice_pipeline/stt.rs` | `SpeechToText` trait + Whisper-via-worker impl |
| `apps/main/src-tauri/src/voice_pipeline/llm.rs` | `ChatModel` trait + streaming gpt-4o-mini-via-worker impl |
| `apps/main/src-tauri/src/voice_pipeline/tts.rs` | `TextToSpeech` trait + Kokoro impl |
| `apps/main/src-tauri/src/voice_pipeline/audio_capture.rs` | Mic input via cpal, feeds PCM frames to VAD |
| `apps/main/src-tauri/src/voice_pipeline/audio_playback.rs` | Speaker output via cpal, sentence playback queue |
| `apps/main/src-tauri/src/voice_pipeline/model_manager.rs` | Download/verify/delete models via hf-hub |
| `apps/main/src-tauri/src/voice_pipeline/streaming.rs` | Sentence buffer — accumulates LLM tokens, emits complete sentences |

### Rust (modified files)

| File | Change |
|------|--------|
| `apps/main/src-tauri/src/lib.rs` | Add `pub mod voice_pipeline;`, register new Tauri commands |
| `apps/main/src-tauri/Cargo.toml` | Add dependencies: `ort`, `hf-hub`, `statig`, `kokoro-rs` |

### Worker (modified files)

| File | Change |
|------|--------|
| `workers/worker/src/index.ts` | Add `/api/audio/transcribe/whisper` and `/api/text/completions/stream` endpoints |

### Frontend (new files)

| File | Responsibility |
|------|---------------|
| `apps/main/src/machines/voicePipelineMachine.ts` | XState mirror machine for UI state |
| `apps/main/src/hooks/useVoicePipeline.ts` | Hook that creates actor, subscribes to Tauri events, updates chatStore |

### Frontend (modified files)

| File | Change |
|------|--------|
| `apps/main/src/stores/chatStore.ts` | Add `pipelineMode`, `pipelineState`, `transcripts`, route `startChat` to modular pipeline |
| `apps/main/src/modules/realtime.ts` | No changes (kept as-is for OpenAI Realtime fallback) |

---

## Task 1: Create Feature Branch

**Files:** None (git operation only)

- [ ] **Step 1: Create and switch to feature branch**

```bash
git checkout -b feat/modular-voice-pipeline
```

- [ ] **Step 2: Verify branch**

```bash
git branch --show-current
```

Expected: `feat/modular-voice-pipeline`

---

## Task 2: Add Rust Dependencies

**Files:**
- Modify: `apps/main/src-tauri/Cargo.toml`

- [ ] **Step 1: Add new dependencies to Cargo.toml**

Add these to the `[dependencies]` section of `apps/main/src-tauri/Cargo.toml`:

```toml
# Voice pipeline
ort = { version = "2", features = ["load-dynamic"] }
hf-hub = "0.4"
statig = "0.3"
kokoro-rs = "0.3"
```

- [ ] **Step 2: Verify dependencies resolve**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -5
```

Expected: Compiles without errors (warnings OK).

- [ ] **Step 3: Commit**

```bash
git add apps/main/src-tauri/Cargo.toml
git commit -m "feat(voice-pipeline): add Rust dependencies for modular voice pipeline"
```

---

## Task 3: Model Manager — Download and Manage Models

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/model_manager.rs`
- Create: `apps/main/src-tauri/src/voice_pipeline/mod.rs`
- Modify: `apps/main/src-tauri/src/lib.rs`

- [ ] **Step 1: Write test for model_manager**

Create `apps/main/src-tauri/src/voice_pipeline/model_manager.rs`:

```rust
use std::path::{Path, PathBuf};

/// Status of voice models on disk.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ModelStatus {
    pub kokoro_ready: bool,
    pub vad_ready: bool,
    pub total_size_bytes: u64,
    pub models_dir: String,
}

/// Returns the models directory under the app's local data dir.
pub fn models_dir(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("models")
}

/// Check which models are present on disk.
pub fn check_models(app_data_dir: &Path) -> ModelStatus {
    let dir = models_dir(app_data_dir);
    let kokoro_path = dir.join("kokoro-v1.0").join("model.onnx");
    let vad_path = dir.join("silero-vad.onnx");

    let kokoro_ready = kokoro_path.exists();
    let vad_ready = vad_path.exists();

    let total_size_bytes = if dir.exists() {
        walkdir::WalkDir::new(&dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter_map(|e| e.metadata().ok())
            .filter(|m| m.is_file())
            .map(|m| m.len())
            .sum()
    } else {
        0
    };

    ModelStatus {
        kokoro_ready,
        vad_ready,
        total_size_bytes,
        models_dir: dir.to_string_lossy().to_string(),
    }
}

/// Delete all downloaded voice models.
pub fn delete_models(app_data_dir: &Path) -> Result<(), String> {
    let dir = models_dir(app_data_dir);
    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| format!("Failed to delete models: {}", e))?;
    }
    Ok(())
}

/// Download models from HuggingFace Hub.
/// Calls `on_progress` with (model_name, percent 0-100).
pub async fn download_models(
    app_data_dir: &Path,
    on_progress: impl Fn(&str, u8) + Send + 'static,
) -> Result<(), String> {
    let dir = models_dir(app_data_dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("Failed to create models dir: {}", e))?;

    let vad_path = dir.join("silero-vad.onnx");
    if !vad_path.exists() {
        on_progress("silero-vad", 0);
        let api = hf_hub::api::tokio::Api::new()
            .map_err(|e| format!("HF API init failed: {}", e))?;
        let repo = api.model("snakers4/silero-vad".to_string());
        let downloaded = repo
            .get("silero_vad.onnx")
            .await
            .map_err(|e| format!("Failed to download Silero VAD: {}", e))?;
        std::fs::copy(&downloaded, &vad_path)
            .map_err(|e| format!("Failed to copy VAD model: {}", e))?;
        on_progress("silero-vad", 100);
    }

    let kokoro_dir = dir.join("kokoro-v1.0");
    let kokoro_model_path = kokoro_dir.join("model.onnx");
    if !kokoro_model_path.exists() {
        on_progress("kokoro", 0);
        std::fs::create_dir_all(&kokoro_dir)
            .map_err(|e| format!("Failed to create kokoro dir: {}", e))?;
        let api = hf_hub::api::tokio::Api::new()
            .map_err(|e| format!("HF API init failed: {}", e))?;
        let repo = api.model("hexgrad/Kokoro-82M-v1.0-ONNX".to_string());

        // Download model file
        on_progress("kokoro", 10);
        let model_file = repo
            .get("model.onnx")
            .await
            .map_err(|e| format!("Failed to download Kokoro model: {}", e))?;
        std::fs::copy(&model_file, &kokoro_model_path)
            .map_err(|e| format!("Failed to copy Kokoro model: {}", e))?;
        on_progress("kokoro", 60);

        // Download default voice
        let voices_dir = kokoro_dir.join("voices");
        std::fs::create_dir_all(&voices_dir)
            .map_err(|e| format!("Failed to create voices dir: {}", e))?;
        let voice_file = repo
            .get("voices/af_heart.bin")
            .await
            .map_err(|e| format!("Failed to download Kokoro voice: {}", e))?;
        std::fs::copy(&voice_file, voices_dir.join("af_heart.bin"))
            .map_err(|e| format!("Failed to copy Kokoro voice: {}", e))?;
        on_progress("kokoro", 100);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_check_models_empty_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let status = check_models(tmp.path());
        assert!(!status.kokoro_ready);
        assert!(!status.vad_ready);
        assert_eq!(status.total_size_bytes, 0);
    }

    #[test]
    fn test_delete_models_no_dir() {
        let tmp = tempfile::tempdir().unwrap();
        // Should not error even if models dir doesn't exist
        delete_models(tmp.path()).unwrap();
    }
}
```

- [ ] **Step 2: Create mod.rs**

Create `apps/main/src-tauri/src/voice_pipeline/mod.rs`:

```rust
pub mod model_manager;
```

- [ ] **Step 3: Register module in lib.rs**

In `apps/main/src-tauri/src/lib.rs`, add after `pub mod local_scanner;`:

```rust
pub mod voice_pipeline;
```

- [ ] **Step 4: Run tests**

```bash
cd apps/main/src-tauri && cargo test voice_pipeline::model_manager -- --nocapture 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/
git add apps/main/src-tauri/src/lib.rs
git commit -m "feat(voice-pipeline): add model manager for downloading and managing voice models"
```

---

## Task 4: Silero VAD Wrapper

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/vad.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write VAD wrapper**

Create `apps/main/src-tauri/src/voice_pipeline/vad.rs`:

```rust
use ort::session::Session;
use std::path::Path;

/// Silero VAD wrapper. Detects speech segments in audio frames.
pub struct SileroVad {
    session: Session,
    /// Internal LSTM state (h, c) — must persist across calls.
    h: ndarray::Array3<f32>,
    c: ndarray::Array3<f32>,
    sample_rate: i64,
    /// Minimum consecutive speech frames to trigger speech start.
    speech_threshold: f32,
    is_speaking: bool,
    /// Count of consecutive frames below threshold (for end-of-speech detection).
    silence_frames: usize,
    /// Number of silence frames before declaring speech ended.
    silence_frames_threshold: usize,
}

impl SileroVad {
    /// Load Silero VAD from an ONNX file.
    /// `sample_rate` should be 16000 (Silero expects 16kHz).
    /// `silence_duration_ms` controls how long silence must persist before speech is considered ended.
    pub fn new(model_path: &Path, sample_rate: u32, silence_duration_ms: u32) -> Result<Self, String> {
        let session = Session::builder()
            .and_then(|b| b.commit_from_file(model_path))
            .map_err(|e| format!("Failed to load Silero VAD: {}", e))?;

        // Silero VAD expects chunks of 512 samples at 16kHz (32ms per chunk)
        let frames_per_chunk = 512;
        let chunks_per_second = sample_rate as f32 / frames_per_chunk as f32;
        let silence_frames_threshold = (silence_duration_ms as f32 / 1000.0 * chunks_per_second) as usize;

        Ok(Self {
            session,
            h: ndarray::Array3::<f32>::zeros((2, 1, 64)),
            c: ndarray::Array3::<f32>::zeros((2, 1, 64)),
            sample_rate: sample_rate as i64,
            speech_threshold: 0.5,
            is_speaking: false,
            silence_frames: 0,
            silence_frames_threshold,
        })
    }

    /// Reset internal state. Call when starting a new listening session.
    pub fn reset(&mut self) {
        self.h = ndarray::Array3::<f32>::zeros((2, 1, 64));
        self.c = ndarray::Array3::<f32>::zeros((2, 1, 64));
        self.is_speaking = false;
        self.silence_frames = 0;
    }

    /// Feed a chunk of 512 PCM f32 samples at 16kHz.
    /// Returns a `VadEvent` indicating what happened.
    pub fn process_chunk(&mut self, audio: &[f32]) -> Result<VadEvent, String> {
        let input = ndarray::Array2::from_shape_vec((1, audio.len()), audio.to_vec())
            .map_err(|e| format!("Failed to create input tensor: {}", e))?;
        let sr = ndarray::Array1::from_vec(vec![self.sample_rate]);

        let outputs = self.session
            .run(ort::inputs![
                "input" => input.view(),
                "sr" => sr.view(),
                "h" => self.h.view(),
                "c" => self.c.view(),
            ].map_err(|e| format!("Failed to create inputs: {}", e))?)
            .map_err(|e| format!("VAD inference failed: {}", e))?;

        // Extract outputs
        let prob = outputs["output"]
            .try_extract_tensor::<f32>()
            .map_err(|e| format!("Failed to extract probability: {}", e))?;
        let speech_prob = prob.as_slice().ok_or("Empty probability output")?[0];

        // Update LSTM states
        if let Ok(hn) = outputs["hn"].try_extract_tensor::<f32>() {
            self.h = hn.to_owned().into_dimensionality().unwrap_or(self.h.clone());
        }
        if let Ok(cn) = outputs["cn"].try_extract_tensor::<f32>() {
            self.c = cn.to_owned().into_dimensionality().unwrap_or(self.c.clone());
        }

        // State machine logic
        if speech_prob >= self.speech_threshold {
            self.silence_frames = 0;
            if !self.is_speaking {
                self.is_speaking = true;
                return Ok(VadEvent::SpeechStart);
            }
            return Ok(VadEvent::Speaking);
        }

        // Below threshold
        if self.is_speaking {
            self.silence_frames += 1;
            if self.silence_frames >= self.silence_frames_threshold {
                self.is_speaking = false;
                self.silence_frames = 0;
                return Ok(VadEvent::SpeechEnd);
            }
            return Ok(VadEvent::Speaking); // still in speech, just a brief pause
        }

        Ok(VadEvent::Silence)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum VadEvent {
    /// No speech detected.
    Silence,
    /// Speech just started in this chunk.
    SpeechStart,
    /// Ongoing speech.
    Speaking,
    /// Speech just ended (silence exceeded threshold).
    SpeechEnd,
}
```

- [ ] **Step 2: Add to mod.rs**

In `apps/main/src-tauri/src/voice_pipeline/mod.rs`, add:

```rust
pub mod vad;
```

- [ ] **Step 3: Verify compilation**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -5
```

Expected: Compiles (may need `ndarray` dependency — add it if the compiler says so).

- [ ] **Step 4: Add ndarray if needed**

If compilation fails due to missing `ndarray`, add to `Cargo.toml`:

```toml
ndarray = "0.16"
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/vad.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git add apps/main/src-tauri/Cargo.toml
git commit -m "feat(voice-pipeline): add Silero VAD wrapper for speech detection"
```

---

## Task 5: STT Trait and Whisper-via-Worker Implementation

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/stt.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write STT trait and implementation**

Create `apps/main/src-tauri/src/voice_pipeline/stt.rs`:

```rust
use async_trait::async_trait;

/// Trait for speech-to-text engines. Implement this to swap in a local STT model later.
#[async_trait]
pub trait SpeechToText: Send + Sync {
    /// Transcribe PCM f32 audio at the given sample rate to text.
    async fn transcribe(&self, audio: &[f32], sample_rate: u32) -> Result<String, String>;
}

/// STT implementation that sends audio to the Cloudflare Worker's Whisper endpoint.
pub struct WhisperWorkerStt {
    worker_url: String,
}

impl WhisperWorkerStt {
    pub fn new(worker_url: &str) -> Self {
        Self {
            worker_url: worker_url.to_string(),
        }
    }
}

#[async_trait]
impl SpeechToText for WhisperWorkerStt {
    async fn transcribe(&self, audio: &[f32], sample_rate: u32) -> Result<String, String> {
        // Convert f32 PCM to 16-bit WAV bytes
        let wav_bytes = pcm_to_wav(audio, sample_rate);

        let token = crate::commands::get_auth_token_standalone()?;
        let client = reqwest::Client::new();

        let url = format!("{}/api/audio/transcribe/whisper", self.worker_url);
        let mut req = client.post(&url);

        if token == "dev-placeholder-token" {
            let secret = option_env!("DEV_BYPASS_SECRET").unwrap_or("");
            req = req.header("X-Dev-Bypass", secret);
        } else {
            req = req.header("Authorization", format!("Bearer {}", token));
        }

        let response = req
            .header("Content-Type", "audio/wav")
            .body(wav_bytes)
            .send()
            .await
            .map_err(|e| format!("STT request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("STT failed ({}): {}", status, body));
        }

        let result: serde_json::Value = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse STT response: {}", e))?;

        result["text"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| "Missing 'text' in STT response".to_string())
    }
}

/// Convert PCM f32 samples to a WAV byte buffer.
fn pcm_to_wav(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let num_samples = samples.len() as u32;
    let byte_rate = sample_rate * 2; // 16-bit mono
    let data_size = num_samples * 2;
    let file_size = 36 + data_size;

    let mut buf = Vec::with_capacity(file_size as usize + 8);

    // RIFF header
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&file_size.to_le_bytes());
    buf.extend_from_slice(b"WAVE");

    // fmt chunk
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // chunk size
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM format
    buf.extend_from_slice(&1u16.to_le_bytes()); // mono
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&2u16.to_le_bytes()); // block align
    buf.extend_from_slice(&16u16.to_le_bytes()); // bits per sample

    // data chunk
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_size.to_le_bytes());
    for &sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        let int_sample = (clamped * 32767.0) as i16;
        buf.extend_from_slice(&int_sample.to_le_bytes());
    }

    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pcm_to_wav_header() {
        let samples = vec![0.0f32; 16000]; // 1 second of silence at 16kHz
        let wav = pcm_to_wav(&samples, 16000);

        // Check RIFF header
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(&wav[36..40], b"data");

        // Total size should be 44 (header) + 32000 (16000 samples * 2 bytes)
        assert_eq!(wav.len(), 44 + 32000);
    }
}
```

- [ ] **Step 2: Add `async-trait` dependency**

In `apps/main/src-tauri/Cargo.toml`:

```toml
async-trait = "0.1"
```

- [ ] **Step 3: Add a standalone auth token helper**

The existing `get_auth_token` requires an `AppHandle`. Add a standalone version to `apps/main/src-tauri/src/commands.rs` that reads directly from keychain:

```rust
/// Standalone auth token retrieval (no AppHandle needed).
/// Used by background services like the voice pipeline.
pub fn get_auth_token_standalone() -> Result<String, String> {
    if let Some(exp_str) = keyring_get("auth_expires_at")? {
        let expires_at: u64 = exp_str.parse().map_err(|_| "Invalid auth_expires_at format")?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        if now > expires_at {
            if tauri::is_dev() {
                return Ok("dev-placeholder-token".to_string());
            }
            return Err("Token expired — please log in again".to_string());
        }
    }

    match keyring_get("auth_token")? {
        Some(token) => Ok(token),
        None if tauri::is_dev() => Ok("dev-placeholder-token".to_string()),
        None => Err("Not authenticated".to_string()),
    }
}
```

- [ ] **Step 4: Add to mod.rs**

```rust
pub mod stt;
```

- [ ] **Step 5: Run tests**

```bash
cd apps/main/src-tauri && cargo test voice_pipeline::stt -- --nocapture 2>&1 | tail -10
```

Expected: `test_pcm_to_wav_header` passes.

- [ ] **Step 6: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/stt.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git add apps/main/src-tauri/src/commands.rs
git add apps/main/src-tauri/Cargo.toml
git commit -m "feat(voice-pipeline): add STT trait and Whisper-via-worker implementation"
```

---

## Task 6: LLM Trait and Streaming Chat Completion

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/llm.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write LLM trait and streaming implementation**

Create `apps/main/src-tauri/src/voice_pipeline/llm.rs`:

```rust
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

/// Trait for chat models. Implement this to swap in a local LLM later.
#[async_trait]
pub trait ChatModel: Send + Sync {
    /// Generate a streaming response. Calls `on_token` for each text chunk.
    /// Returns the full concatenated response.
    async fn complete_streaming(
        &self,
        messages: Vec<Message>,
        on_token: Box<dyn Fn(&str) + Send>,
    ) -> Result<String, String>;
}

/// LLM implementation that streams from the worker's SSE endpoint.
pub struct WorkerChatModel {
    worker_url: String,
    model: String,
}

impl WorkerChatModel {
    pub fn new(worker_url: &str, model: &str) -> Self {
        Self {
            worker_url: worker_url.to_string(),
            model: model.to_string(),
        }
    }
}

#[async_trait]
impl ChatModel for WorkerChatModel {
    async fn complete_streaming(
        &self,
        messages: Vec<Message>,
        on_token: Box<dyn Fn(&str) + Send>,
    ) -> Result<String, String> {
        let token = crate::commands::get_auth_token_standalone()?;
        let client = reqwest::Client::new();

        let url = format!("{}/api/text/completions/stream", self.worker_url);
        let body = serde_json::json!({
            "messages": messages,
            "model": self.model,
        });

        let mut req = client.post(&url);
        if token == "dev-placeholder-token" {
            let secret = option_env!("DEV_BYPASS_SECRET").unwrap_or("");
            req = req.header("X-Dev-Bypass", secret);
        } else {
            req = req.header("Authorization", format!("Bearer {}", token));
        }

        let response = req
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("LLM request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("LLM failed ({}): {}", status, body));
        }

        // Read SSE stream
        let mut full_response = String::new();
        let mut stream = response.bytes_stream();

        use futures_util::StreamExt;
        let mut buffer = String::new();

        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| format!("Stream error: {}", e))?;
            let text = String::from_utf8_lossy(&chunk);
            buffer.push_str(&text);

            // Parse SSE lines
            while let Some(newline_pos) = buffer.find('\n') {
                let line = buffer[..newline_pos].trim().to_string();
                buffer = buffer[newline_pos + 1..].to_string();

                if line.starts_with("data: ") {
                    let data = &line[6..];
                    if data == "[DONE]" {
                        continue;
                    }
                    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(data) {
                        if let Some(content) = parsed["choices"][0]["delta"]["content"].as_str() {
                            on_token(content);
                            full_response.push_str(content);
                        }
                    }
                }
            }
        }

        Ok(full_response)
    }
}

/// Build the messages array for a book-context-aware conversation.
pub fn build_messages(transcript: &str, book_context: &[String], conversation_history: &[Message]) -> Vec<Message> {
    let system_prompt = "You are a teacher and educational assistant inside a reading application. \
        Your role is to help the user understand the book they are reading. \
        Keep responses concise (2-4 sentences) since they will be spoken aloud. \
        Use simple, clear language. Break down complex concepts. \
        If book context is provided, ground your answers in that text. \
        If the context doesn't contain enough information, say so clearly.";

    let mut messages = vec![Message {
        role: "system".to_string(),
        content: system_prompt.to_string(),
    }];

    // Add conversation history
    messages.extend_from_slice(conversation_history);

    // Build user message with context
    let user_content = if book_context.is_empty() {
        transcript.to_string()
    } else {
        let context_text = book_context.join("\n\n");
        format!(
            "<book_context>\n{}\n</book_context>\n\n{}",
            context_text, transcript
        )
    };

    messages.push(Message {
        role: "user".to_string(),
        content: user_content,
    });

    messages
}
```

- [ ] **Step 2: Add `futures-util` dependency**

In `apps/main/src-tauri/Cargo.toml`:

```toml
futures-util = "0.3"
```

- [ ] **Step 3: Add to mod.rs**

```rust
pub mod llm;
```

- [ ] **Step 4: Verify compilation**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/llm.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git add apps/main/src-tauri/Cargo.toml
git commit -m "feat(voice-pipeline): add ChatModel trait and streaming worker LLM implementation"
```

---

## Task 7: Sentence Buffer — LLM Tokens to TTS Sentences

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/streaming.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write sentence buffer with tests**

Create `apps/main/src-tauri/src/voice_pipeline/streaming.rs`:

```rust
/// Accumulates streaming LLM tokens and emits complete sentences.
pub struct SentenceBuffer {
    buffer: String,
}

impl SentenceBuffer {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
        }
    }

    /// Feed a token into the buffer. Returns a complete sentence if one is ready.
    pub fn push(&mut self, token: &str) -> Option<String> {
        self.buffer.push_str(token);

        // Look for sentence boundaries: . ? ! followed by space or end
        if let Some(pos) = self.find_sentence_end() {
            let sentence = self.buffer[..=pos].trim().to_string();
            self.buffer = self.buffer[pos + 1..].to_string();
            if sentence.is_empty() {
                return None;
            }
            return Some(sentence);
        }

        None
    }

    /// Flush any remaining text as a final sentence.
    pub fn flush(&mut self) -> Option<String> {
        let remaining = self.buffer.trim().to_string();
        self.buffer.clear();
        if remaining.is_empty() {
            None
        } else {
            Some(remaining)
        }
    }

    fn find_sentence_end(&self) -> Option<usize> {
        let bytes = self.buffer.as_bytes();
        for (i, &b) in bytes.iter().enumerate() {
            if (b == b'.' || b == b'?' || b == b'!') && i + 1 < bytes.len() {
                let next = bytes[i + 1];
                // Sentence ends at punctuation followed by space, newline, or quote
                if next == b' ' || next == b'\n' || next == b'"' || next == b'\'' {
                    return Some(i);
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_sentence() {
        let mut buf = SentenceBuffer::new();
        assert_eq!(buf.push("Hello "), None);
        assert_eq!(buf.push("world. "), Some("Hello world.".to_string()));
    }

    #[test]
    fn test_question_mark() {
        let mut buf = SentenceBuffer::new();
        assert_eq!(buf.push("How are you? "), Some("How are you?".to_string()));
    }

    #[test]
    fn test_multiple_sentences() {
        let mut buf = SentenceBuffer::new();
        assert_eq!(buf.push("First. "), Some("First.".to_string()));
        assert_eq!(buf.push("Second. "), Some("Second.".to_string()));
    }

    #[test]
    fn test_flush_incomplete() {
        let mut buf = SentenceBuffer::new();
        assert_eq!(buf.push("No ending here"), None);
        assert_eq!(buf.flush(), Some("No ending here".to_string()));
    }

    #[test]
    fn test_abbreviation_not_split() {
        // Periods not followed by space should not split
        let mut buf = SentenceBuffer::new();
        assert_eq!(buf.push("Dr.Smith"), None);
        assert_eq!(buf.flush(), Some("Dr.Smith".to_string()));
    }

    #[test]
    fn test_token_by_token() {
        let mut buf = SentenceBuffer::new();
        let tokens = ["The ", "book ", "explains ", "this. ", "Let ", "me "];
        let mut sentences = vec![];
        for t in &tokens {
            if let Some(s) = buf.push(t) {
                sentences.push(s);
            }
        }
        if let Some(s) = buf.flush() {
            sentences.push(s);
        }
        assert_eq!(sentences, vec!["The book explains this.", "Let me"]);
    }
}
```

- [ ] **Step 2: Add to mod.rs**

```rust
pub mod streaming;
```

- [ ] **Step 3: Run tests**

```bash
cd apps/main/src-tauri && cargo test voice_pipeline::streaming -- --nocapture 2>&1 | tail -15
```

Expected: All 6 tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/streaming.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git commit -m "feat(voice-pipeline): add sentence buffer for streaming LLM tokens to TTS"
```

---

## Task 8: TTS Trait and Kokoro Implementation

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/tts.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write TTS trait and Kokoro implementation**

Create `apps/main/src-tauri/src/voice_pipeline/tts.rs`:

```rust
use std::path::Path;

/// Trait for text-to-speech engines. Implement this to swap TTS providers.
pub trait TextToSpeech: Send + Sync {
    /// Synthesize text into PCM f32 audio samples at the engine's sample rate.
    fn synthesize(&self, text: &str) -> Result<Vec<f32>, String>;

    /// The sample rate of the output audio.
    fn sample_rate(&self) -> u32;
}

/// Kokoro TTS implementation using kokoro-rs.
pub struct KokoroTts {
    model: kokoro_rs::Kokoro,
    voice_name: String,
    output_sample_rate: u32,
}

impl KokoroTts {
    /// Initialize Kokoro from a model directory.
    /// `model_dir` should contain `model.onnx` and `voices/af_heart.bin`.
    pub fn new(model_dir: &Path) -> Result<Self, String> {
        let model_path = model_dir.join("model.onnx");
        let voice_path = model_dir.join("voices").join("af_heart.bin");

        if !model_path.exists() {
            return Err(format!("Kokoro model not found: {:?}", model_path));
        }
        if !voice_path.exists() {
            return Err(format!("Kokoro voice not found: {:?}", voice_path));
        }

        let model = kokoro_rs::Kokoro::new(
            model_path.to_str().ok_or("Invalid model path")?,
            voice_path.to_str().ok_or("Invalid voice path")?,
        )
        .map_err(|e| format!("Failed to initialize Kokoro: {}", e))?;

        Ok(Self {
            model,
            voice_name: "af_heart".to_string(),
            output_sample_rate: 24000, // Kokoro outputs at 24kHz
        })
    }
}

impl TextToSpeech for KokoroTts {
    fn synthesize(&self, text: &str) -> Result<Vec<f32>, String> {
        if text.trim().is_empty() {
            return Ok(vec![]);
        }

        let audio = self.model
            .speak(text)
            .map_err(|e| format!("Kokoro synthesis failed: {}", e))?;

        Ok(audio)
    }

    fn sample_rate(&self) -> u32 {
        self.output_sample_rate
    }
}
```

- [ ] **Step 2: Add to mod.rs**

```rust
pub mod tts;
```

- [ ] **Step 3: Verify compilation**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -5
```

Note: The `kokoro-rs` crate API may differ from what's shown above. Check the crate docs and adjust the `new()` and `speak()` calls to match the actual API. The trait interface stays the same regardless.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/tts.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git commit -m "feat(voice-pipeline): add TextToSpeech trait and Kokoro implementation"
```

---

## Task 9: Audio Capture and Playback via cpal

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/audio_capture.rs`
- Create: `apps/main/src-tauri/src/voice_pipeline/audio_playback.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write audio capture module**

Create `apps/main/src-tauri/src/voice_pipeline/audio_capture.rs`:

```rust
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// Captures audio from the default input device at 16kHz mono.
/// Sends chunks of 512 f32 samples through the channel.
pub struct AudioCapture {
    stream: Option<cpal::Stream>,
}

impl AudioCapture {
    /// Start capturing audio. Returns a receiver that yields 512-sample chunks.
    pub fn start() -> Result<(Self, mpsc::Receiver<Vec<f32>>), String> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No input device available")?;

        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(16000),
            buffer_size: cpal::BufferSize::Default,
        };

        let (tx, rx) = mpsc::channel::<Vec<f32>>(64);
        let chunk_buffer = Arc::new(Mutex::new(Vec::with_capacity(512)));

        let chunk_buf = chunk_buffer.clone();
        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let mut buf = chunk_buf.lock().unwrap();
                    buf.extend_from_slice(data);

                    while buf.len() >= 512 {
                        let chunk: Vec<f32> = buf.drain(..512).collect();
                        let _ = tx.try_send(chunk);
                    }
                },
                |err| {
                    eprintln!("[audio_capture] Stream error: {}", err);
                },
                None,
            )
            .map_err(|e| format!("Failed to build input stream: {}", e))?;

        stream.play().map_err(|e| format!("Failed to start capture: {}", e))?;

        Ok((Self { stream: Some(stream) }, rx))
    }

    /// Stop capturing audio.
    pub fn stop(&mut self) {
        self.stream = None;
    }
}
```

- [ ] **Step 2: Write audio playback module**

Create `apps/main/src-tauri/src/voice_pipeline/audio_playback.rs`:

```rust
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

/// Plays PCM f32 audio through the default output device.
pub struct AudioPlayback {
    stream: Option<cpal::Stream>,
    is_playing: Arc<AtomicBool>,
    queue: Arc<Mutex<Vec<Vec<f32>>>>,
}

impl AudioPlayback {
    /// Create a new audio playback instance.
    pub fn new() -> Result<Self, String> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or("No output device available")?;

        let is_playing = Arc::new(AtomicBool::new(false));
        let queue: Arc<Mutex<Vec<Vec<f32>>>> = Arc::new(Mutex::new(Vec::new()));
        let sample_index = Arc::new(Mutex::new(0usize));
        let current_buffer: Arc<Mutex<Option<Vec<f32>>>> = Arc::new(Mutex::new(None));

        let queue_ref = queue.clone();
        let playing_ref = is_playing.clone();
        let si = sample_index.clone();
        let cb = current_buffer.clone();

        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(24000), // Kokoro outputs 24kHz
            buffer_size: cpal::BufferSize::Default,
        };

        let stream = device
            .build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let mut idx = si.lock().unwrap();
                    let mut buf = cb.lock().unwrap();

                    for sample in data.iter_mut() {
                        // Try to get current buffer
                        if buf.is_none() {
                            let mut q = queue_ref.lock().unwrap();
                            if let Some(next) = q.first().cloned() {
                                q.remove(0);
                                *buf = Some(next);
                                *idx = 0;
                            }
                        }

                        if let Some(ref audio) = *buf {
                            if *idx < audio.len() {
                                *sample = audio[*idx];
                                *idx += 1;
                            } else {
                                // Buffer exhausted, try next
                                *buf = None;
                                *sample = 0.0;
                            }
                        } else {
                            *sample = 0.0;
                            playing_ref.store(false, Ordering::Relaxed);
                        }
                    }
                },
                |err| {
                    eprintln!("[audio_playback] Stream error: {}", err);
                },
                None,
            )
            .map_err(|e| format!("Failed to build output stream: {}", e))?;

        stream.play().map_err(|e| format!("Failed to start playback: {}", e))?;

        Ok(Self {
            stream: Some(stream),
            is_playing,
            queue,
        })
    }

    /// Queue audio for playback.
    pub fn enqueue(&self, audio: Vec<f32>) {
        let mut q = self.queue.lock().unwrap();
        q.push(audio);
        self.is_playing.store(true, Ordering::Relaxed);
    }

    /// Clear all queued audio (for interruption).
    pub fn clear(&self) {
        let mut q = self.queue.lock().unwrap();
        q.clear();
        self.is_playing.store(false, Ordering::Relaxed);
    }

    /// Check if audio is currently playing or queued.
    pub fn is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Relaxed)
            || !self.queue.lock().unwrap().is_empty()
    }

    /// Stop playback and release the stream.
    pub fn stop(&mut self) {
        self.clear();
        self.stream = None;
    }
}
```

- [ ] **Step 3: Add to mod.rs**

```rust
pub mod audio_capture;
pub mod audio_playback;
```

- [ ] **Step 4: Verify compilation**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/audio_capture.rs
git add apps/main/src-tauri/src/voice_pipeline/audio_playback.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git commit -m "feat(voice-pipeline): add cpal audio capture and playback modules"
```

---

## Task 10: State Machine with statig

**Files:**
- Create: `apps/main/src-tauri/src/voice_pipeline/machine.rs`
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`

- [ ] **Step 1: Write the state machine**

Create `apps/main/src-tauri/src/voice_pipeline/machine.rs`:

```rust
use serde::{Deserialize, Serialize};

/// Pipeline states as a simple enum (used for Tauri events and frontend mirror).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PipelineState {
    Idle,
    Initializing,
    Downloading,
    Listening,
    ProcessingSTT,
    ProcessingLLM,
    Speaking,
    Error,
}

/// Events that drive state transitions.
#[derive(Debug, Clone)]
pub enum PipelineEvent {
    Start,
    ModelsReady,
    ModelsMissing,
    DownloadComplete,
    DownloadError(String),
    SpeechEnd(Vec<f32>), // captured audio
    TranscriptReady(String),
    FirstSentence(String),
    PlaybackComplete,
    Interrupted,
    Stop,
    Retry,
    LlmError(String),
    SttError(String),
}

/// Simple state machine for the voice pipeline.
/// Uses a match-based approach for clarity and testability.
pub struct PipelineMachine {
    state: PipelineState,
}

impl PipelineMachine {
    pub fn new() -> Self {
        Self {
            state: PipelineState::Idle,
        }
    }

    pub fn state(&self) -> PipelineState {
        self.state
    }

    /// Process an event and return the new state (or None if transition is invalid).
    pub fn transition(&mut self, event: &PipelineEvent) -> Option<PipelineState> {
        let new_state = match (&self.state, event) {
            // From Idle
            (PipelineState::Idle, PipelineEvent::Start) => Some(PipelineState::Initializing),

            // From Initializing
            (PipelineState::Initializing, PipelineEvent::ModelsReady) => Some(PipelineState::Listening),
            (PipelineState::Initializing, PipelineEvent::ModelsMissing) => Some(PipelineState::Downloading),

            // From Downloading
            (PipelineState::Downloading, PipelineEvent::DownloadComplete) => Some(PipelineState::Listening),
            (PipelineState::Downloading, PipelineEvent::DownloadError(_)) => Some(PipelineState::Error),

            // From Listening
            (PipelineState::Listening, PipelineEvent::SpeechEnd(_)) => Some(PipelineState::ProcessingSTT),
            (PipelineState::Listening, PipelineEvent::Stop) => Some(PipelineState::Idle),

            // From ProcessingSTT
            (PipelineState::ProcessingSTT, PipelineEvent::TranscriptReady(_)) => Some(PipelineState::ProcessingLLM),
            (PipelineState::ProcessingSTT, PipelineEvent::SttError(_)) => Some(PipelineState::Error),

            // From ProcessingLLM
            (PipelineState::ProcessingLLM, PipelineEvent::FirstSentence(_)) => Some(PipelineState::Speaking),
            (PipelineState::ProcessingLLM, PipelineEvent::LlmError(_)) => Some(PipelineState::Error),

            // From Speaking
            (PipelineState::Speaking, PipelineEvent::PlaybackComplete) => Some(PipelineState::Listening),
            (PipelineState::Speaking, PipelineEvent::Interrupted) => Some(PipelineState::Listening),
            (PipelineState::Speaking, PipelineEvent::Stop) => Some(PipelineState::Idle),

            // From Error
            (PipelineState::Error, PipelineEvent::Retry) => Some(PipelineState::Listening),
            (PipelineState::Error, PipelineEvent::Stop) => Some(PipelineState::Idle),

            // Global stop
            (_, PipelineEvent::Stop) => Some(PipelineState::Idle),

            _ => None,
        };

        if let Some(s) = new_state {
            self.state = s;
        }

        new_state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_happy_path() {
        let mut m = PipelineMachine::new();
        assert_eq!(m.state(), PipelineState::Idle);

        m.transition(&PipelineEvent::Start);
        assert_eq!(m.state(), PipelineState::Initializing);

        m.transition(&PipelineEvent::ModelsReady);
        assert_eq!(m.state(), PipelineState::Listening);

        m.transition(&PipelineEvent::SpeechEnd(vec![]));
        assert_eq!(m.state(), PipelineState::ProcessingSTT);

        m.transition(&PipelineEvent::TranscriptReady("hello".into()));
        assert_eq!(m.state(), PipelineState::ProcessingLLM);

        m.transition(&PipelineEvent::FirstSentence("Hi there!".into()));
        assert_eq!(m.state(), PipelineState::Speaking);

        m.transition(&PipelineEvent::PlaybackComplete);
        assert_eq!(m.state(), PipelineState::Listening);

        m.transition(&PipelineEvent::Stop);
        assert_eq!(m.state(), PipelineState::Idle);
    }

    #[test]
    fn test_download_path() {
        let mut m = PipelineMachine::new();
        m.transition(&PipelineEvent::Start);
        m.transition(&PipelineEvent::ModelsMissing);
        assert_eq!(m.state(), PipelineState::Downloading);

        m.transition(&PipelineEvent::DownloadComplete);
        assert_eq!(m.state(), PipelineState::Listening);
    }

    #[test]
    fn test_interruption() {
        let mut m = PipelineMachine::new();
        m.transition(&PipelineEvent::Start);
        m.transition(&PipelineEvent::ModelsReady);
        m.transition(&PipelineEvent::SpeechEnd(vec![]));
        m.transition(&PipelineEvent::TranscriptReady("hi".into()));
        m.transition(&PipelineEvent::FirstSentence("Hello!".into()));
        assert_eq!(m.state(), PipelineState::Speaking);

        m.transition(&PipelineEvent::Interrupted);
        assert_eq!(m.state(), PipelineState::Listening);
    }

    #[test]
    fn test_error_recovery() {
        let mut m = PipelineMachine::new();
        m.transition(&PipelineEvent::Start);
        m.transition(&PipelineEvent::ModelsReady);
        m.transition(&PipelineEvent::SpeechEnd(vec![]));
        m.transition(&PipelineEvent::SttError("timeout".into()));
        assert_eq!(m.state(), PipelineState::Error);

        m.transition(&PipelineEvent::Retry);
        assert_eq!(m.state(), PipelineState::Listening);
    }

    #[test]
    fn test_global_stop() {
        let mut m = PipelineMachine::new();
        m.transition(&PipelineEvent::Start);
        m.transition(&PipelineEvent::ModelsReady);
        m.transition(&PipelineEvent::SpeechEnd(vec![]));
        assert_eq!(m.state(), PipelineState::ProcessingSTT);

        m.transition(&PipelineEvent::Stop);
        assert_eq!(m.state(), PipelineState::Idle);
    }
}
```

- [ ] **Step 2: Add to mod.rs**

```rust
pub mod machine;
```

- [ ] **Step 3: Run tests**

```bash
cd apps/main/src-tauri && cargo test voice_pipeline::machine -- --nocapture 2>&1 | tail -15
```

Expected: All 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/machine.rs
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git commit -m "feat(voice-pipeline): add pipeline state machine with full test coverage"
```

---

## Task 11: Pipeline Orchestrator and Tauri Commands

**Files:**
- Modify: `apps/main/src-tauri/src/voice_pipeline/mod.rs`
- Modify: `apps/main/src-tauri/src/lib.rs`

- [ ] **Step 1: Write the pipeline orchestrator in mod.rs**

Replace the contents of `apps/main/src-tauri/src/voice_pipeline/mod.rs` with:

```rust
pub mod audio_capture;
pub mod audio_playback;
pub mod llm;
pub mod machine;
pub mod model_manager;
pub mod stt;
pub mod streaming;
pub mod tts;
pub mod vad;

use machine::{PipelineEvent, PipelineMachine, PipelineState};
use model_manager::ModelStatus;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::mpsc;

/// Shared pipeline state accessible from Tauri commands.
struct PipelineHandle {
    stop_tx: Option<mpsc::Sender<()>>,
    machine: PipelineMachine,
}

static PIPELINE: std::sync::OnceLock<Arc<Mutex<PipelineHandle>>> = std::sync::OnceLock::new();

fn get_pipeline() -> &'static Arc<Mutex<PipelineHandle>> {
    PIPELINE.get_or_init(|| {
        Arc::new(Mutex::new(PipelineHandle {
            stop_tx: None,
            machine: PipelineMachine::new(),
        }))
    })
}

fn emit_state(app: &AppHandle, state: PipelineState) {
    let _ = app.emit("voice-pipeline:state", serde_json::json!({ "state": state }));
}

fn emit_transcript(app: &AppHandle, role: &str, text: &str) {
    let _ = app.emit(
        "voice-pipeline:transcript",
        serde_json::json!({ "role": role, "text": text }),
    );
}

fn emit_download_progress(app: &AppHandle, percent: u8, model: &str) {
    let _ = app.emit(
        "voice-pipeline:download-progress",
        serde_json::json!({ "percent": percent, "model": model }),
    );
}

fn emit_error(app: &AppHandle, message: &str) {
    let _ = app.emit(
        "voice-pipeline:error",
        serde_json::json!({ "message": message }),
    );
}

#[tauri::command]
pub async fn start_voice_chat(app: AppHandle, book_id: i64) -> Result<(), String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;

    let (stop_tx, mut stop_rx) = mpsc::channel::<()>(1);

    // Store stop sender
    {
        let mut handle = get_pipeline().lock().unwrap();
        handle.stop_tx = Some(stop_tx);
        handle.machine.transition(&PipelineEvent::Start);
        emit_state(&app, PipelineState::Initializing);
    }

    // Check models
    let status = model_manager::check_models(&app_data_dir);
    if !status.kokoro_ready || !status.vad_ready {
        {
            let mut handle = get_pipeline().lock().unwrap();
            handle.machine.transition(&PipelineEvent::ModelsMissing);
            emit_state(&app, PipelineState::Downloading);
        }

        let app_ref = app.clone();
        model_manager::download_models(&app_data_dir, move |model, percent| {
            emit_download_progress(&app_ref, percent, model);
        })
        .await?;

        let mut handle = get_pipeline().lock().unwrap();
        handle.machine.transition(&PipelineEvent::DownloadComplete);
    } else {
        let mut handle = get_pipeline().lock().unwrap();
        handle.machine.transition(&PipelineEvent::ModelsReady);
    }

    emit_state(&app, PipelineState::Listening);

    // Initialize components
    let models_dir = model_manager::models_dir(&app_data_dir);
    let vad_path = models_dir.join("silero-vad.onnx");
    let kokoro_dir = models_dir.join("kokoro-v1.0");

    let mut vad_engine = vad::SileroVad::new(&vad_path, 16000, 800)?;
    let stt_engine: Box<dyn stt::SpeechToText> =
        Box::new(stt::WhisperWorkerStt::new(crate::WORKER_URL));
    let llm_engine: Box<dyn llm::ChatModel> =
        Box::new(llm::WorkerChatModel::new(crate::WORKER_URL, "gpt-4o-mini"));
    let tts_engine = tts::KokoroTts::new(&kokoro_dir)?;
    let mut playback = audio_playback::AudioPlayback::new()?;

    let mut conversation_history: Vec<llm::Message> = Vec::new();

    // Start mic capture
    let (mut capture, mut audio_rx) = audio_capture::AudioCapture::start()?;
    let mut speech_buffer: Vec<f32> = Vec::new();
    let mut is_capturing_speech = false;

    // Main loop
    loop {
        tokio::select! {
            _ = stop_rx.recv() => {
                // Stop requested
                capture.stop();
                playback.stop();
                let mut handle = get_pipeline().lock().unwrap();
                handle.machine.transition(&PipelineEvent::Stop);
                emit_state(&app, PipelineState::Idle);
                break;
            }

            chunk = audio_rx.recv() => {
                let Some(chunk) = chunk else { break; };

                let current_state = get_pipeline().lock().unwrap().machine.state();

                match current_state {
                    PipelineState::Listening => {
                        match vad_engine.process_chunk(&chunk) {
                            Ok(vad::VadEvent::SpeechStart) => {
                                is_capturing_speech = true;
                                speech_buffer.clear();
                                speech_buffer.extend_from_slice(&chunk);
                            }
                            Ok(vad::VadEvent::Speaking) if is_capturing_speech => {
                                speech_buffer.extend_from_slice(&chunk);
                            }
                            Ok(vad::VadEvent::SpeechEnd) if is_capturing_speech => {
                                speech_buffer.extend_from_slice(&chunk);
                                is_capturing_speech = false;

                                let audio = std::mem::take(&mut speech_buffer);

                                // Transition to ProcessingSTT
                                {
                                    let mut handle = get_pipeline().lock().unwrap();
                                    handle.machine.transition(&PipelineEvent::SpeechEnd(vec![]));
                                }
                                emit_state(&app, PipelineState::ProcessingSTT);

                                // STT
                                match stt_engine.transcribe(&audio, 16000).await {
                                    Ok(transcript) if !transcript.trim().is_empty() => {
                                        emit_transcript(&app, "user", &transcript);
                                        {
                                            let mut handle = get_pipeline().lock().unwrap();
                                            handle.machine.transition(&PipelineEvent::TranscriptReady(transcript.clone()));
                                        }
                                        emit_state(&app, PipelineState::ProcessingLLM);

                                        // Get book context
                                        let book_context = crate::sql::get_context_for_query(
                                            transcript.clone(),
                                            book_id as u32,
                                            &app_data_dir,
                                            3,
                                        )
                                        .await
                                        .unwrap_or_default();

                                        let messages = llm::build_messages(
                                            &transcript,
                                            &book_context,
                                            &conversation_history,
                                        );

                                        // LLM streaming
                                        let mut sentence_buf = streaming::SentenceBuffer::new();
                                        let mut first_sentence_sent = false;
                                        let mut full_response = String::new();

                                        let tts_ref = &tts_engine;
                                        let playback_ref = &playback;
                                        let app_ref = app.clone();

                                        match llm_engine.complete_streaming(
                                            messages,
                                            Box::new(move |token| {
                                                // This closure runs on each token — we can't do
                                                // TTS here because it's sync. Tokens are collected
                                                // by the trait impl and returned as full_response.
                                            }),
                                        ).await {
                                            Ok(response) => {
                                                full_response = response.clone();

                                                // Process full response through sentence buffer
                                                let mut sentence_buf = streaming::SentenceBuffer::new();
                                                // Feed the response word by word to simulate streaming
                                                for word in response.split_inclusive(' ') {
                                                    if let Some(sentence) = sentence_buf.push(word) {
                                                        if !first_sentence_sent {
                                                            first_sentence_sent = true;
                                                            let mut handle = get_pipeline().lock().unwrap();
                                                            handle.machine.transition(&PipelineEvent::FirstSentence(sentence.clone()));
                                                            emit_state(&app, PipelineState::Speaking);
                                                        }
                                                        // Synthesize and enqueue
                                                        if let Ok(audio) = tts_engine.synthesize(&sentence) {
                                                            playback.enqueue(audio);
                                                        }
                                                    }
                                                }
                                                // Flush remaining
                                                if let Some(sentence) = sentence_buf.flush() {
                                                    if !first_sentence_sent {
                                                        let mut handle = get_pipeline().lock().unwrap();
                                                        handle.machine.transition(&PipelineEvent::FirstSentence(sentence.clone()));
                                                        emit_state(&app, PipelineState::Speaking);
                                                    }
                                                    if let Ok(audio) = tts_engine.synthesize(&sentence) {
                                                        playback.enqueue(audio);
                                                    }
                                                }

                                                emit_transcript(&app, "assistant", &full_response);

                                                // Update conversation history
                                                conversation_history.push(llm::Message {
                                                    role: "user".to_string(),
                                                    content: transcript,
                                                });
                                                conversation_history.push(llm::Message {
                                                    role: "assistant".to_string(),
                                                    content: full_response,
                                                });

                                                // Wait for playback to finish
                                                while playback.is_playing() {
                                                    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

                                                    // Check for stop or interruption
                                                    if stop_rx.try_recv().is_ok() {
                                                        playback.clear();
                                                        capture.stop();
                                                        playback.stop();
                                                        let mut handle = get_pipeline().lock().unwrap();
                                                        handle.machine.transition(&PipelineEvent::Stop);
                                                        emit_state(&app, PipelineState::Idle);
                                                        return Ok(());
                                                    }
                                                }

                                                // Back to listening
                                                let mut handle = get_pipeline().lock().unwrap();
                                                handle.machine.transition(&PipelineEvent::PlaybackComplete);
                                                emit_state(&app, PipelineState::Listening);
                                                vad_engine.reset();
                                            }
                                            Err(e) => {
                                                let mut handle = get_pipeline().lock().unwrap();
                                                handle.machine.transition(&PipelineEvent::LlmError(e.clone()));
                                                emit_state(&app, PipelineState::Error);
                                                emit_error(&app, &e);
                                            }
                                        }
                                    }
                                    Ok(_) => {
                                        // Empty transcript, go back to listening
                                        let mut handle = get_pipeline().lock().unwrap();
                                        handle.machine.transition(&PipelineEvent::Retry);
                                        emit_state(&app, PipelineState::Listening);
                                        vad_engine.reset();
                                    }
                                    Err(e) => {
                                        let mut handle = get_pipeline().lock().unwrap();
                                        handle.machine.transition(&PipelineEvent::SttError(e.clone()));
                                        emit_state(&app, PipelineState::Error);
                                        emit_error(&app, &e);
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    PipelineState::Speaking => {
                        // Check for interruption (user speaking while assistant is talking)
                        if let Ok(vad::VadEvent::SpeechStart) = vad_engine.process_chunk(&chunk) {
                            playback.clear();
                            is_capturing_speech = true;
                            speech_buffer.clear();
                            speech_buffer.extend_from_slice(&chunk);
                            let mut handle = get_pipeline().lock().unwrap();
                            handle.machine.transition(&PipelineEvent::Interrupted);
                            emit_state(&app, PipelineState::Listening);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    Ok(())
}

#[tauri::command]
pub fn stop_voice_chat() -> Result<(), String> {
    let handle = get_pipeline().lock().unwrap();
    if let Some(tx) = &handle.stop_tx {
        let _ = tx.try_send(());
    }
    Ok(())
}

#[tauri::command]
pub fn get_voice_model_status(app: AppHandle) -> Result<ModelStatus, String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;
    Ok(model_manager::check_models(&app_data_dir))
}

#[tauri::command]
pub fn delete_voice_models(app: AppHandle) -> Result<(), String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?;
    model_manager::delete_models(&app_data_dir)
}
```

- [ ] **Step 2: Register commands in lib.rs**

In `apps/main/src-tauri/src/lib.rs`, add the voice pipeline commands to the `invoke_handler`:

```rust
// Voice pipeline commands
voice_pipeline::start_voice_chat,
voice_pipeline::stop_voice_chat,
voice_pipeline::get_voice_model_status,
voice_pipeline::delete_voice_models,
```

Add these after the `local_scanner::cancel_scan,` line.

- [ ] **Step 3: Verify compilation**

```bash
cd apps/main/src-tauri && cargo check 2>&1 | tail -10
```

Fix any compilation errors. The main orchestrator ties together all modules, so this is where integration issues surface.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/voice_pipeline/mod.rs
git add apps/main/src-tauri/src/lib.rs
git commit -m "feat(voice-pipeline): add pipeline orchestrator and Tauri commands"
```

---

## Task 12: Worker Endpoints — Whisper STT and Streaming Completions

**Files:**
- Modify: `workers/worker/src/index.ts`

- [ ] **Step 1: Add Whisper STT endpoint**

In `workers/worker/src/index.ts`, add after the existing `/api/audio/transcribe` endpoint (after line 804):

```typescript
// ─── POST /api/audio/transcribe/whisper — OpenAI Whisper STT proxy ──────────
app.post("/api/audio/transcribe/whisper", requireWorkerAuth, async (c) => {
  const contentType = c.req.header("Content-Type") || "audio/wav";
  const audioData = await c.req.arrayBuffer();

  if (audioData.byteLength === 0) {
    return c.json({ error: "Empty audio data" }, 400);
  }

  const openai = new OpenAI({
    apiKey: c.env.OPENAI_API_KEY,
  });

  try {
    const file = new File([audioData], "audio.wav", { type: contentType });
    const transcription = await openai.audio.transcriptions.create({
      file,
      model: "whisper-1",
      language: "en",
    });

    return c.json({ text: transcription.text });
  } catch (error) {
    if (error instanceof OpenAI.APIError) {
      console.error("Whisper API error:", error.status, error.message);
      return c.json(
        { error: `Whisper STT error: ${error.message}` },
        error.status === 429 ? 429 : 502
      );
    }
    if (error instanceof Error) {
      return c.json({ error: "STT failed: " + error.message }, 500);
    }
    return c.json({ error: "STT failed" }, 500);
  }
});
```

- [ ] **Step 2: Add streaming chat completion endpoint**

Add after the Whisper endpoint:

```typescript
// ─── POST /api/text/completions/stream — Streaming chat completions ─────────
app.post("/api/text/completions/stream", requireWorkerAuth, async (c) => {
  const { messages, model } = await c.req.json<{
    messages: { role: string; content: string }[];
    model?: string;
  }>();

  if (!messages || messages.length === 0) {
    return c.json({ error: "Messages array is required" }, 400);
  }

  const openai = new OpenAI({
    apiKey: c.env.OPENAI_API_KEY,
  });

  const stream = await openai.chat.completions.create({
    model: model || "gpt-4o-mini",
    messages,
    stream: true,
  });

  // Convert to SSE response
  const encoder = new TextEncoder();
  const readable = new ReadableStream({
    async start(controller) {
      try {
        for await (const chunk of stream) {
          const data = JSON.stringify(chunk);
          controller.enqueue(encoder.encode(`data: ${data}\n\n`));
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch (error) {
        controller.error(error);
      }
    },
  });

  return new Response(readable, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
});
```

- [ ] **Step 3: Verify worker builds**

```bash
cd workers/worker && npx wrangler deploy --dry-run 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add workers/worker/src/index.ts
git commit -m "feat(voice-pipeline): add Whisper STT and streaming chat completion worker endpoints"
```

---

## Task 13: Frontend XState Mirror Machine

**Files:**
- Create: `apps/main/src/machines/voicePipelineMachine.ts`

- [ ] **Step 1: Write the mirror machine**

Create `apps/main/src/machines/voicePipelineMachine.ts`:

```typescript
import { setup, assign } from "xstate";

export type VoicePipelineState =
  | "idle"
  | "initializing"
  | "downloading"
  | "listening"
  | "processingSTT"
  | "processingLLM"
  | "speaking"
  | "error";

export type VoicePipelineContext = {
  downloadProgress: number | null;
  downloadModel: string | null;
  errorMessage: string | null;
};

export type VoicePipelineEvent =
  | { type: "STATE_UPDATE"; state: VoicePipelineState }
  | { type: "DOWNLOAD_PROGRESS"; percent: number; model: string }
  | { type: "ERROR"; message: string }
  | { type: "RESET" };

export const voicePipelineMachine = setup({
  types: {
    context: {} as VoicePipelineContext,
    events: {} as VoicePipelineEvent,
  },
  actions: {
    setDownloadProgress: assign({
      downloadProgress: ({ event }) =>
        event.type === "DOWNLOAD_PROGRESS" ? event.percent : null,
      downloadModel: ({ event }) =>
        event.type === "DOWNLOAD_PROGRESS" ? event.model : null,
    }),
    setError: assign({
      errorMessage: ({ event }) =>
        event.type === "ERROR" ? event.message : null,
    }),
    clearError: assign({ errorMessage: null }),
    clearProgress: assign({ downloadProgress: null, downloadModel: null }),
  },
}).createMachine({
  id: "voicePipelineMirror",
  initial: "idle",
  context: {
    downloadProgress: null,
    downloadModel: null,
    errorMessage: null,
  },
  states: {
    idle: {
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "initializing", target: "initializing" },
          { guard: ({ event }) => event.state === "downloading", target: "downloading" },
          { guard: ({ event }) => event.state === "listening", target: "listening" },
        ],
      },
    },
    initializing: {
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "downloading", target: "downloading" },
          { guard: ({ event }) => event.state === "listening", target: "listening" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    downloading: {
      on: {
        DOWNLOAD_PROGRESS: { actions: "setDownloadProgress" },
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "listening", target: "listening", actions: "clearProgress" },
          { guard: ({ event }) => event.state === "error", target: "error" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    listening: {
      entry: "clearError",
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "processingSTT", target: "processingSTT" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    processingSTT: {
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "processingLLM", target: "processingLLM" },
          { guard: ({ event }) => event.state === "error", target: "error" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    processingLLM: {
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "speaking", target: "speaking" },
          { guard: ({ event }) => event.state === "error", target: "error" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    speaking: {
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "listening", target: "listening" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
      },
    },
    error: {
      entry: "setError",
      on: {
        STATE_UPDATE: [
          { guard: ({ event }) => event.state === "listening", target: "listening" },
          { guard: ({ event }) => event.state === "idle", target: "idle" },
        ],
        ERROR: { actions: "setError" },
      },
    },
  },
});
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/machines/voicePipelineMachine.ts
git commit -m "feat(voice-pipeline): add XState mirror machine for frontend UI state"
```

---

## Task 14: useVoicePipeline Hook

**Files:**
- Create: `apps/main/src/hooks/useVoicePipeline.ts`

- [ ] **Step 1: Write the hook**

Create `apps/main/src/hooks/useVoicePipeline.ts`:

```typescript
import { useEffect, useRef } from "react";
import { createActor } from "xstate";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { voicePipelineMachine, type VoicePipelineState } from "@/machines/voicePipelineMachine";
import { useChatStore } from "@/stores/chatStore";

interface VoicePipelinePayload {
  state: VoicePipelineState;
}

interface TranscriptPayload {
  role: "user" | "assistant";
  text: string;
}

interface DownloadProgressPayload {
  percent: number;
  model: string;
}

interface ErrorPayload {
  message: string;
}

export function useVoicePipeline() {
  const actorRef = useRef<ReturnType<typeof createActor> | null>(null);

  useEffect(() => {
    const actor = createActor(voicePipelineMachine);
    actorRef.current = actor;
    actor.start();

    const unlisteners: UnlistenFn[] = [];

    // Subscribe to Tauri events
    const setup = async () => {
      unlisteners.push(
        await listen<VoicePipelinePayload>("voice-pipeline:state", (event) => {
          actor.send({ type: "STATE_UPDATE", state: event.payload.state });

          // Sync pipelineState to chatStore
          useChatStore.getState().setPipelineState(event.payload.state);
        })
      );

      unlisteners.push(
        await listen<TranscriptPayload>("voice-pipeline:transcript", (event) => {
          useChatStore.getState().addTranscript(event.payload.role, event.payload.text);
        })
      );

      unlisteners.push(
        await listen<DownloadProgressPayload>("voice-pipeline:download-progress", (event) => {
          actor.send({
            type: "DOWNLOAD_PROGRESS",
            percent: event.payload.percent,
            model: event.payload.model,
          });
          useChatStore.getState().setDownloadProgress(event.payload.percent);
        })
      );

      unlisteners.push(
        await listen<ErrorPayload>("voice-pipeline:error", (event) => {
          actor.send({ type: "ERROR", message: event.payload.message });
        })
      );
    };

    setup();

    // Sync actor state to chatStore
    const sub = actor.subscribe((snapshot) => {
      const stateValue = snapshot.value as string;
      useChatStore.getState().setPipelineState(stateValue as VoicePipelineState);
    });

    return () => {
      sub.unsubscribe();
      unlisteners.forEach((unlisten) => unlisten());
      actor.stop();
    };
  }, []);
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/hooks/useVoicePipeline.ts
git commit -m "feat(voice-pipeline): add useVoicePipeline hook for Tauri event subscription"
```

---

## Task 15: Update chatStore for Pipeline Mode

**Files:**
- Modify: `apps/main/src/stores/chatStore.ts`

- [ ] **Step 1: Update chatStore**

Replace the contents of `apps/main/src/stores/chatStore.ts` with:

```typescript
import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime } from "@/modules/realtime";
import { usePlayerStore } from "./playerStore";
import { invoke } from "@tauri-apps/api/core";

type PipelineMode = "openai-realtime" | "modular";
type PipelineState =
  | "idle"
  | "initializing"
  | "downloading"
  | "listening"
  | "processingSTT"
  | "processingLLM"
  | "speaking"
  | "error";

interface Transcript {
  role: "user" | "assistant";
  text: string;
}

interface ChatState {
  isChatting: boolean;
  pipelineMode: PipelineMode;
  pipelineState: PipelineState;
  downloadProgress: number | null;
  transcripts: Transcript[];
  realtimeSession: RealtimeSession | null;

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void;
  startChat: (bookId: number) => void;
  stopConversation: () => void;
  setPipelineMode: (mode: PipelineMode) => void;
  setPipelineState: (state: PipelineState) => void;
  setDownloadProgress: (percent: number | null) => void;
  addTranscript: (role: "user" | "assistant", text: string) => void;
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        isChatting: false,
        pipelineMode: "modular" as PipelineMode, // default to modular on feature branch
        pipelineState: "idle" as PipelineState,
        downloadProgress: null,
        transcripts: [],
        realtimeSession: null,

        setIsChatting: (value) => {
          const newValue =
            typeof value === "function" ? value(get().isChatting) : value;
          if (newValue) {
            // Stop TTS playback — chat and TTS are mutually exclusive
            const send = usePlayerStore.getState().send;
            if (send) send({ type: "CHAT_STARTED" });
          }
          set({ isChatting: newValue });
        },

        startChat: (bookId: number) => {
          const { pipelineMode } = get();

          // Stop TTS playback
          const send = usePlayerStore.getState().send;
          if (send) send({ type: "CHAT_STARTED" });

          set({ isChatting: true, transcripts: [] });

          if (pipelineMode === "modular") {
            // Use modular voice pipeline (Rust-native)
            invoke("start_voice_chat", { bookId: BigInt(bookId) }).catch(
              (err) => {
                console.error("[chatStore] Failed to start voice chat:", err);
                set({ isChatting: false, pipelineState: "error" });
              }
            );
          } else {
            // Use OpenAI Realtime API (existing)
            void startRealtime(bookId).then((session) => {
              set({ realtimeSession: session });
            });
          }
        },

        stopConversation: () => {
          const { realtimeSession, pipelineMode } = get();

          if (pipelineMode === "modular") {
            invoke("stop_voice_chat").catch((err) => {
              console.error("[chatStore] Failed to stop voice chat:", err);
            });
          } else if (realtimeSession) {
            realtimeSession.close();
          }

          set({
            realtimeSession: null,
            isChatting: false,
            pipelineState: "idle",
          });
        },

        setPipelineMode: (mode) => set({ pipelineMode: mode }),
        setPipelineState: (state) => set({ pipelineState: state }),
        setDownloadProgress: (percent) => set({ downloadProgress: percent }),
        addTranscript: (role, text) =>
          set((state) => ({
            transcripts: [...state.transcripts, { role, text }],
          })),
      })
    ),
    { name: "chat-store" }
  )
);
```

- [ ] **Step 2: Verify TypeScript compilation**

```bash
cd apps/main && npx tsc --noEmit 2>&1 | grep chatStore | head -5
```

Expected: No errors related to chatStore.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/stores/chatStore.ts
git commit -m "feat(voice-pipeline): update chatStore with pipeline mode routing and modular state"
```

---

## Task 16: Regenerate Tauri Type Bindings

**Files:**
- Modify: `apps/main/src/generated/commands.ts` (auto-generated)
- Modify: `apps/main/src/generated/types.ts` (auto-generated)

- [ ] **Step 1: Regenerate types**

```bash
cd apps/main && bun run generate-types
```

- [ ] **Step 2: Verify new commands appear**

```bash
grep -n "voice" apps/main/src/generated/commands.ts
```

Expected: Should show `startVoiceChat`, `stopVoiceChat`, `getVoiceModelStatus`, `deleteVoiceModels` functions.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/generated/
git commit -m "chore: regenerate Tauri type bindings for voice pipeline commands"
```

---

## Task 17: Integration Test — Full Pipeline Smoke Test

**Files:**
- No new files (manual verification)

- [ ] **Step 1: Build the full app**

```bash
cd apps/main && cargo tauri build --debug 2>&1 | tail -20
```

Expected: Build succeeds.

- [ ] **Step 2: Verify the app starts**

```bash
cd apps/main && cargo tauri dev &
```

Test manually:
1. App starts without crashes
2. Existing TTS playback still works (playerMachine not broken)
3. Tapping the chat orb triggers the modular pipeline (check console for `voice-pipeline:state` events)
4. Models download on first use (progress shown)
5. After models download, mic capture starts (check system audio permissions)

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix(voice-pipeline): integration fixes from smoke test"
```

---

## Task 18: Final Cleanup and Documentation

- [ ] **Step 1: Verify all tests pass**

```bash
cd apps/main/src-tauri && cargo test voice_pipeline -- --nocapture 2>&1 | tail -20
```

Expected: All unit tests pass (model_manager, streaming, machine).

- [ ] **Step 2: Verify no TypeScript errors**

```bash
cd apps/main && npx tsc --noEmit 2>&1 | tail -10
```

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat(voice-pipeline): complete modular voice pipeline implementation"
```

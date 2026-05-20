# Voice-Chat VAD Gating — Design

**Date:** 2026-05-20
**Status:** Approved, pre-implementation
**Scope:** apps/rishi-electron — voice chat activation pipeline

## Problem

Today the buffered-speech replay in `services/voice-chat/activation-program.ts` cuts the recorder off the instant WebRTC `connect()` resolves. If the user is mid-sentence at that moment, Deepgram gets a half-utterance, the agent responds to a partial thought, then the live mic opens while the user is still speaking and the tail of their sentence interrupts the agent's response. Result: jarring stop-and-resume behavior on first turn.

## Goal

Hold the recorder open until the user actually pauses, then transcribe and send. Also reduce server-side VAD sensitivity so live-mic interruptions are less twitchy.

## Approach

Energy-based local VAD via Web Audio `AnalyserNode` + smoothed RMS polling. Gate the "stop recorder → transcribe → sendMessage → mute(false)" sequence on (connect resolved) AND (VAD says user has stopped speaking, with a hangover). Also raise OpenAI Realtime server-side `turn_detection.threshold` from default 0.5 to 0.7 via the GA `config.audio.input.turnDetection` path.

Silero VAD (`@ricky0123/vad-web`) is documented as a future swap-in option (Approach C). The `LocalVoiceVad` interface is library-agnostic; a Silero-backed implementation would replace `local-vad.ts` and be DI-swapped in `services/index.ts` without other call-site changes. Reach for it if energy-based detection proves unreliable across mics/rooms or when additional agent personas are added.

## Architecture

### New file

`apps/rishi-electron/src/renderer/src/services/voice-chat/local-vad.ts`

Mirrors the `key-cache.ts` factory pattern: a named factory function (`createLocalVad`) accepting a `MediaStreamLike` + `LocalVadConfig`, holding internal mutable state in closure variables, returning a typed `LocalVoiceVad`. Internal state fully hidden.

### Modified files

- `services/voice-chat/types.ts` — new types: `LocalVadConfig`, `ServerVadConfig`, `LocalVoiceVad`, `VadPort`. Extends `VoiceChatServiceDeps` with `vad: VadPort`, `VoiceChatConfig` with `localVad: LocalVadConfig` and `serverVad: ServerVadConfig`, and `SessionFactoryOpts` with `serverVad: ServerVadConfig`.
- `services/voice-chat/activation-program.ts` — adds VAD `acquireRelease` between mic and recorder; gates `replayBufferedSpeech` on `vad.waitForSpeechEnd(timeoutMs)`. Extends `SessionHandle` with `vad: LocalVoiceVad | null`.
- `services/voice-chat/service.ts` — disposes the VAD inside `disposeInternal()`.
- `services/index.ts` — wires the `vad` port (inline literal calling `createLocalVad`) and `serverVad` in the `sessionFactory` (translates to `new RealtimeSession(agent, { transport, apiKey, config: { audio: { input: { turnDetection } } } })`).
- `services/voice-chat/service.test.ts` — adds `makeVad()` factory; extends `makeConfig()` with `localVad`/`serverVad` defaults; adds four new edge-case tests.

### Public interfaces

```ts
export interface LocalVadConfig {
  rmsThreshold: number      // [0,1]; default 0.05
  hangoverMs: number        // silence ms before declaring end-of-utterance; default 700
  pollIntervalMs: number    // default 50
  fftSize: number           // default 256
}

export interface ServerVadConfig {
  threshold: number              // default 0.7 (raised from OpenAI's 0.5)
  silenceDurationMs?: number     // default 700
  prefixPaddingMs?: number       // default 300
}

export interface LocalVoiceVad {
  /** Sticky for instance lifetime. Cleared only by dispose+reconstruct. */
  everSpoke(): boolean
  /**
   * Resolves when VAD observes silence-hangover after speech, OR immediately
   * if everSpoke() is false (nothing to wait for), OR immediately if already
   * past hangover. Rejects with VadTimeoutError on timeout, VadDisposedError
   * on dispose-while-waiting.
   */
  waitForSpeechEnd(timeoutMs: number): Promise<void>
  /** Stop polling, close AudioContext. Idempotent. */
  dispose(): void
}

export interface VadPort {
  /** Returns null if AudioContext is unavailable — pipeline treats as VAD-disabled. */
  create(stream: MediaStreamLike): LocalVoiceVad | null
}
```

`localVad` and `serverVad` are **required** (not optional) on `VoiceChatConfig`. Optional fields create silent regressions: a caller that forgets `serverVad` would ship the OpenAI default 0.5 forever. Required forces every wiring site to be explicit, and tests get defaults via `makeConfig()`.

`serverVad` belongs in `SessionFactoryOpts`, not piped through as raw OpenAI types. Keeps SDK shape leakage confined to the `sessionFactory` lambda in `services/index.ts`.

### Activation pipeline ordering

Inside `activationPipeline`'s `Effect.scoped` / `Effect.gen`:

```
1. acquireRelease: mediaStream         (getUserMedia)
2. acquireRelease: audioElement        (createAudioElement)
3. acquireRelease: vad                 (deps.vad.create(mediaStream))    ← new
4. acquireRelease: built               (buildSession; passes serverVad)
5. acquireRelease: buffered            (SpeechBuffer recorder)
6. yield: keyCacheGet                  (apiKey fetch)
7. yield: session.connect + timeout    (connect gate)
8. yield: vad?.waitForSpeechEnd(...)   (VAD gate)                        ← new
9. yield: replayBufferedSpeech         (if buffered)
10. yield: mute(false) + unmute audio
11. success = true
```

VAD is acquired before `built` so its finalizer runs in resource-dependency order. Safety timeout for `waitForSpeechEnd` reuses `connectTimeoutMs` (same budget as the connect step that just completed).

### Edge cases

| Case | Behavior |
|---|---|
| User never speaks during connect | `everSpoke()` false → `waitForSpeechEnd` resolves immediately → no transcript injected → mic opens silent → agent waits |
| User speaks then stops before connect resolves | `everSpoke()` true, hangover already past → resolves immediately → transcript injected → mic opens |
| User still mid-sentence when connect resolves | `waitForSpeechEnd` waits for hangover → transcript injected → mic opens. Recorder keeps capturing the tail because `stop()` is only called inside `replayBufferedSpeech` after `waitForSpeechEnd` returns. |
| Speech-end never fires (noise floor too low, mic stuck) | `connectTimeoutMs` safety timeout → `VadTimeoutError` → pipeline proceeds with whatever was buffered |
| `AudioContext` unavailable | `createLocalVad` catches inside its try/catch → returns `null` → activation pipeline skips VAD gate (degrades to current behavior) |
| `MediaRecorder` unavailable | Existing path: skip transcript replay entirely. VAD still works on the stream. |
| Activation interrupted mid-`waitForSpeechEnd` | `acquireRelease` finalizer disposes VAD → `VadDisposedError` rejects the promise → Effect drops the rejection on interrupt |

### Failure modes

- `new AudioContext()` throws → caught inside `createLocalVad`; returns null.
- `createMediaStreamSource` throws → caught; AudioContext closed defensively; returns null.
- Polling interval fires after dispose → guarded with internal `disposed` flag; callback no-ops.
- `waitForSpeechEnd` called after dispose → rejects synchronously with `VadDisposedError`.
- Safety timeout firing mid-`replayBufferedSpeech` → cannot happen; the timeout governs only step 8; once resolved, the timer is cleared before step 9.

### Config defaults

In `services/index.ts`:

```ts
localVad: {
  rmsThreshold: 0.05,
  hangoverMs: 700,
  pollIntervalMs: 50,
  fftSize: 256
}
serverVad: {
  threshold: 0.7,
  silenceDurationMs: 700,
  prefixPaddingMs: 300
}
```

Same values in `service.test.ts:makeConfig()`.

## Test strategy

### `local-vad.test.ts` (new)

Fake `AudioContext` whose analyser writes scripted RMS arrays into the time-domain buffer. Cases:
- Silent throughout → `everSpoke()` false; `waitForSpeechEnd(1000)` resolves immediately.
- Brief speech then silence → `everSpoke()` true; `waitForSpeechEnd` resolves after `hangoverMs`.
- Speech still active → `waitForSpeechEnd` blocks; resolves after subsequent silence + hangover.
- Mid-wait dispose → rejects with `VadDisposedError`.
- Timeout exceeded → rejects with `VadTimeoutError`.
- `AudioContext` constructor throws → factory returns null.

### `service.test.ts` (extend)

Inject a fake VAD via `makeVad()` with imperative controls (`emitSpeechStart()`, `emitSpeechEnd()`, `setEverSpoke(bool)`). Add four cases:
1. User never spoke → no `sendMessage` call; live mic opens; no extra Deepgram call.
2. User spoke then stopped before connect resolves → `sendMessage(transcript)` called once, before `mute(false)`.
3. User still speaking when connect resolves → `mute(false)` is NOT called until after `emitSpeechEnd()` + hangover ticks; `sendMessage` happens between.
4. VAD safety timeout → after `connectTimeoutMs`, pipeline proceeds and `mute(false)` is called even though no `emitSpeechEnd()` was ever sent.

## Server-side VAD wiring

In `services/index.ts:sessionFactory`:

```ts
sessionFactory: (agent, opts) =>
  new RealtimeSession(agent, {
    transport: opts.transport,
    apiKey: opts.apiKey,
    config: {
      audio: {
        input: {
          turnDetection: {
            type: 'server_vad',
            threshold: opts.serverVad.threshold,
            silenceDurationMs: opts.serverVad.silenceDurationMs,
            prefixPaddingMs: opts.serverVad.prefixPaddingMs
          }
        }
      }
    }
  })
```

Uses the GA path verified at `node_modules/@openai/agents-realtime/dist/clientMessages.d.ts:65-69`. The deprecated top-level `turnDetection` is avoided.

The `service.ts` warm-path (`updateAgent` reuse) does not need to re-apply `serverVad` — the session keeps its initial config across `updateAgent` calls.

## Production gotchas

- `AudioContext` starts suspended-until-gesture; voice chat is already gesture-gated so this is moot, but `audioCtx.resume()` is called defensively after construction.
- `getFloatTimeDomainData` returns floats in [-1, 1]; RMS is `sqrt(mean(sample²))`. AGC (already on the mic) keeps amplitudes normalized enough that a fixed 0.05 threshold is reliable for utterance-boundary detection. If field reports show drift, tune via config — no code change.
- `setInterval(50ms)` polling could miss sub-50ms transients but is fine for end-of-utterance detection. No need for `AudioWorklet` (and avoids the Electron CSP `file://` quirk it has).
- `serverVad` must use the GA `config.audio.input.turnDetection` path. Both camelCase and snake_case work; we use camelCase to match the rest of the codebase.

## Naming decisions

- `waitForSpeechEnd` over `awaitSilence` — communicates that you're waiting for an utterance to complete (presupposes speech started).
- `everSpoke()` over `hasSpeech` / `detected` — past-tense predicate matches the sticky semantics.
- `VadPort.create` over `attach` — parallels `MediaPort.createAudioElement` / `createMediaRecorder`.
- `LocalVadConfig` (not `VadConfig`) — disambiguates from `ServerVadConfig` living next to it.

## Go/no-go

**Ship it.** Energy-based VAD is well-scoped, the SDK path is verified, all failure modes degrade to existing behavior via the no-op fallback. No feature flag needed.

## Future option — Silero VAD (Approach C)

Documented for future reference if energy-based detection proves insufficient (e.g., when additional agent personas with different acoustic profiles are added). Migration steps:

1. Add `@ricky0123/vad-web` (~4.42 MB total with ONNX model + onnxruntime-web WASM) to `apps/rishi-electron/package.json`.
2. Create `services/voice-chat/silero-vad.ts` implementing the same `LocalVoiceVad` interface backed by Silero.
3. Swap the `createLocalVad` import in `services/index.ts` for `createSileroVad`.
4. Update bundler config to expose the ONNX runtime WASM files at a resolvable path (`onnxWASMBasePath`) — non-trivial in Electron's asar context.

No `activation-program.ts` or `service.ts` changes — the interface is the seam.

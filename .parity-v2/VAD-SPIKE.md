# VAD-SPIKE — T-P0.1
**Date:** 2026-06-04
**Decision:** **BRANCH B (DEFER VAD-001)**

One-line reason: `react-native-audio-api` does NOT implement `createMediaStreamSource` today (Software Mansion issue #872 targets v0.12/v0.13, currently shipping v0.12.2), so there is no way to feed `react-native-webrtc`'s mic `MediaStream` into a Web-Audio `AnalyserNode` on RN — and the shared VAD's entire contract is built on exactly that path.

---

## 1. Current versions (mobile worktree)

From `apps/mobile/package.json` (HEAD of `phase4-floating-widgets` worktree):

| Package | Installed | Notes |
|---|---|---|
| `expo` | `~54.0.33` | SDK 54 |
| `react` | `19.1.0` | |
| `react-native` | `0.81.5` | **NOT** in the `0.83–0.86` range |
| `react-native-reanimated` | `~4.1.1` | actual peer-dep verified for `4.1.4` below |
| `react-native-worklets` | `0.5.1` | exact pin |
| `react-native-webrtc` | `^124.0.7` | exact registry-latest |
| `react-native-audio-api` | **NOT INSTALLED** | would have to be added |

No file under `apps/mobile/` or `packages/shared/` currently imports `react-native-audio-api` (verified via grep). The mobile `VadPort` (`apps/mobile/lib/voice-chat/service.ts:65`) calls `createLocalVad(stream, …)` which returns `null` because `globalThis.AudioContext` is absent — the activation pipeline degrades gracefully.

## 2. Peer-dep compatibility matrix

Pulled live from `registry.npmjs.org` on 2026-06-04:

| Package | Latest | RN peer | worklets peer | Compatible with installed RN 0.81.5? |
|---|---|---|---|---|
| `react-native-reanimated@4.4.1` (latest) | 4.4.1 | `0.83 - 0.86` | `0.9.x` | ❌ requires RN 0.83+ |
| `react-native-reanimated@4.1.4` (installed range) | 4.1.4 | `*` | `>=0.5.0` | ✅ — accepts any RN, worklets ≥0.5 |
| `react-native-worklets@0.9.1` (latest) | 0.9.1 | RN `0.83 - 0.86` | — | ❌ requires RN 0.83+ |
| `react-native-worklets@0.5.1` (installed) | 0.5.1 | — | — | ✅ current |
| `react-native-audio-api@0.12.2` (latest) | 0.12.2 | RN `*`, worklets `>=0.6.0` (optional) | — | ✅ peer-deps satisfied — but see §3 |
| `react-native-webrtc@124.0.7` | 124.0.7 | RN `>=0.60.0` | — | ✅ |

**Sub-finding (the "worklets 0.6+" gate from PLAN.md constraint C):**
- `react-native-reanimated@4.1.4` (already installed) allows `worklets >=0.5.0`, so we CAN bump `worklets` from `0.5.1` → any `0.6.x – 0.8.x` without touching Reanimated.
- Bumping `worklets` to `0.9.x` is technically allowed by Reanimated 4.1.4's `>=0.5.0` peer range, BUT `worklets@0.9.x` itself requires `react-native 0.83-0.86`. Mobile is on RN 0.81.5 → **0.9.x is not viable without also upgrading RN+Reanimated** (out of scope for VAD-001).
- Highest worklets version that is safe to install today, no RN upgrade required: **`react-native-worklets@0.8.x`** (the last line before the 0.83 RN floor was introduced in 0.9.0). Worklets 0.6/0.7/0.8 do satisfy `react-native-audio-api@0.12.2`'s optional `>=0.6.0` peer.

**So the worklets/Reanimated gate is technically GREEN.** It is not the blocker. See §3.

## 3. Raw PCM access on mobile — THE blocker

The shared VAD's contract (`packages/shared/src/voice-chat/local-vad.ts:33-46`) requires:
1. A `new AudioContext()` that supports `createMediaStreamSource(stream)` returning a node connectable to an `AnalyserNode`.
2. `AnalyserNode.getFloatTimeDomainData(Float32Array)` polled at `pollIntervalMs` (default 50 ms) over an `fftSize: 256` window.

Two candidate paths on RN, both blocked:

### Path A — `react-native-audio-api`'s `AudioContext` (the Web-Audio polyfill)
- Confirmed via Software Mansion's GitHub issue tracker:
  - **Issue [#872](https://github.com/software-mansion/react-native-audio-api/issues/872) — "MediaStream Source/Destination Support for WebRTC Audio Processing"** — OPEN as of 2026-06-04. Maintainer `maciejmakowski2003` commented (2026-01-15): *"already present in our road map. it should be added with v0.13 (maybe v0.12)."* Current published version is **0.12.2** and the API is still not present (no `createMediaStreamSource` symbol exported; `MediaStreamAudioSourceNode` class absent).
  - **Issue [#669](https://github.com/software-mansion/react-native-audio-api/issues/669) — "MediaStreamAudioSourceNode"** — closed as `completed`, but the close refers to the mic-as-source path (`react-native-audio-api`'s OWN microphone module), NOT to accepting an external `MediaStream` from `react-native-webrtc`. The shared VAD specifically needs the latter — it must analyse the SAME stream that's about to be sent over the peer connection, so the AEC/AGC chain stays consistent.
- Net: `react-native-audio-api@0.12.2` cannot accept a `react-native-webrtc` `MediaStream`. There is no JS-level glue between the two libraries.

### Path B — `react-native-webrtc` exposes raw PCM directly
- Per the upstream `BasicUsage.md` and a grep over the package's public TypeScript types, `react-native-webrtc@124.0.7` exposes only:
  - `getUserMedia()` → `MediaStream`
  - `MediaStreamTrack.enabled / .stop() / .clone()`
  - `RTCPeerConnection.addTrack(track, stream)` (transmission side)
  - Remote-track volume control via the private `_setVolume()` extension.
- There is **no** `getRawAudio()`, no `onAudioFrame` callback, no `enableAudioProcessing`, no audio worklet bridge, no MediaStreamTrackProcessor equivalent. The local mic stream is opaque to JS — the audio data goes from native capture straight into the WebRTC SDK's encoder.
- Confirmed by Daily.co's React Native SDK docs (referenced in audio-api issue #872) noting the same gap.

### Verdict on §3
Neither path exists today. To run RMS-based VAD on the same mic stream the WebRTC peer connection is consuming, we need (audio-api **+** issue #872 shipped) OR (webrtc **+** a new audio-frame tap). Both are upstream-blocked.

## 4. Electron's VAD input shape (reference)

`apps/rishi-electron/src/renderer/src/services/voice-chat/local-vad.ts` is byte-for-byte structurally identical to the shared `packages/shared/src/voice-chat/local-vad.ts` it was ported from. It:
- Calls `new AudioContext()` (browser-native, Chromium in the Electron renderer).
- Calls `ctx.createMediaStreamSource(stream)` where `stream` is the same `MediaStream` returned by `navigator.mediaDevices.getUserMedia({ audio: true })` and reused for the `RTCPeerConnection`.
- Polls `analyser.getFloatTimeDomainData(new Float32Array(256))` every 50 ms.
- Sample rate is whatever the OS gives the AudioContext (typically 48 kHz on macOS/Linux, 44.1 kHz on Windows); the RMS computation is sample-rate-agnostic because it averages instantaneous amplitudes, not time-windowed energy.

The shared VAD therefore expects:
- Input: `Float32Array(fftSize)` time-domain samples in the standard Web-Audio `[-1.0, +1.0]` range.
- Source: a `MediaStream` that is *the same instance* feeding the WebRTC encoder (so VAD and codec see identical audio — important for end-of-utterance accuracy).
- Glue: standards-compliant `createMediaStreamSource` + `AnalyserNode`. There is no PCM-via-worklets path in the current implementation.

## 5. Decision and reasoning

**BRANCH B — defer VAD-001.**

The orchestrator constraint (PLAN.md §C) requires deferral *"if `react-native-worklets@^0.6.0` (or higher compatible) breaks Reanimated peer-deps OR `react-native-webrtc` does not expose raw PCM"*. Worklets 0.6+ is peer-dep-clean, but **raw PCM is not accessible** from `react-native-webrtc@124.0.7` (§3 Path B) AND the standard Web-Audio bridge for it does not yet exist in `react-native-audio-api@0.12.2` (§3 Path A, upstream issue #872 open).

Implementing VAD-001 today would require a native module fork of either `react-native-webrtc` (to surface mic PCM as a JS `ArrayBuffer` callback) or `react-native-audio-api` (to implement `MediaStreamAudioSourceNode` against a webrtc `MediaStreamTrack`). Both are sizeable scope expansions and are explicitly out-of-scope per constraint C.

## 6. If BRANCH A: implementation outline
N/A — see §7.

## 7. BRANCH B: blocker description and what would unblock it

**Blocker:** No JS-level path from a `react-native-webrtc` local audio `MediaStreamTrack` to a Web-Audio `AnalyserNode`'s `getFloatTimeDomainData` on iOS/Android.

**Specific unblock conditions (any ONE would flip this to Branch A):**
1. **`react-native-audio-api` ships `AudioContext.createMediaStreamSource` accepting a `react-native-webrtc` `MediaStream`.** Tracked in Software Mansion issue [#872](https://github.com/software-mansion/react-native-audio-api/issues/872). Maintainer commitment as of 2026-01-15 is "v0.13 (maybe v0.12)" — current published is 0.12.2 with the API still absent. Re-check on each `react-native-audio-api` minor release.
2. **`react-native-webrtc` exposes an audio-frame callback** (`MediaStreamTrack.onAudioFrame` or equivalent) returning `{ samples: Float32Array, sampleRate: number }` per ~50 ms slice. No tracking issue; would need to be filed upstream.
3. **A native bridge module is built** that taps into iOS `AVAudioEngine` / Android `AudioRecord` *in parallel with* WebRTC's capture (acceptable VAD accuracy if AEC isn't catastrophic on the duplicate path). Estimated 5-10 day spike — explicitly out of scope per constraint C.

**Per spec §3.10 acceptance criterion 5,** a follow-up investigation note (`.parity-v2/VAD-001-investigation.md`) should be opened with the same evidence and a `revisit-on:` flag for the next `react-native-audio-api` minor release.

---

**Sources consulted (read-only):**
- `apps/mobile/package.json` (mobile worktree HEAD)
- `apps/mobile/lib/voice-chat/{service,media-port}.ts`
- `packages/shared/src/voice-chat/{local-vad,types,activation-program}.ts`
- `apps/rishi-electron/src/renderer/src/services/voice-chat/local-vad.ts`
- `https://registry.npmjs.org/react-native-{worklets,reanimated,audio-api,webrtc}` (peer-dep manifests for installed AND latest versions)
- `gh api repos/software-mansion/react-native-audio-api/issues/{872,669}` (incl. maintainer comment thread)
- `react-native-webrtc/Documentation/BasicUsage.md`

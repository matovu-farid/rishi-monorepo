# VAD-001 — Investigation Result (Spec §3.10 criterion 5)

**Date:** 2026-06-04
**Decision:** BRANCH B — DEFER VAD-001 to a future round.

See `.parity-v2/VAD-SPIKE.md` for the full compatibility matrix and evidence.

## Summary of the blocker

The worklets/Reanimated gate is GREEN — Reanimated 4.1.4 accepts `react-native-worklets >= 0.5.0`, so 0.6/0.7/0.8 are usable without disturbing the RN stack.

The actual blocker is upstream:
- `react-native-audio-api@0.12.2` does NOT implement `createMediaStreamSource` (Software Mansion issue #872, maintainer targeting v0.13).
- `react-native-webrtc@124.0.7` exposes no raw-PCM / audio-frame API.

Without either path there is no way to feed the WebRTC mic stream into a Web-Audio-style `AnalyserNode` on RN, which is the shared VAD's entire input contract.

## What would unblock

Either:
1. `react-native-audio-api` 0.13+ ships `createMediaStreamSource` (track Software Mansion #872), OR
2. `react-native-webrtc` exposes a raw-PCM tap (no upstream PR known), OR
3. We commit a native module that bridges the WebRTC track to a Float32Array stream (out of scope this round per orchestrator constraint C).

## Consequence

T-P2.7 (mobile VAD implementation) is closed as DEFERRED. PLAN task count drops from 21 to 20. VAD-001 moves from SPEC §3.10 in-scope to §4 deferred (track this in REVISION-NOTES-02).

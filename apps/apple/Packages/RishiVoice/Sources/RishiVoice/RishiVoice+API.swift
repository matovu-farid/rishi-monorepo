// RishiVoice — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiVoice exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiVoice is the real-time voice chat surface: mic permission
// gate, ephemeral-key fetch, OpenAI Realtime client adapter, and
// the SwiftUI views that show status / transcripts.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 3 unused exports).

// MARK: - Views
//
// VoiceSessionView            — `UI/VoiceSessionView.swift`. The full voice-chat screen.
//                                Shows status badge + transcript + mic button.
// VoiceStatusBadge            — `UI/VoiceStatusBadge.swift`. Pill view that reflects
//                                VoiceSessionStatus (connecting, listening, speaking, ...).
// VoiceErrorView              — `UI/VoiceErrorView.swift`. Inline error state with retry.
// VoicePermissionPrompt       — `UI/VoicePermissionPrompt.swift`. Pre-permission card asking
//                                the user to grant mic access before the system prompt.

// MARK: - State
//
// VoiceSessionState           — `State/VoiceSessionState.swift`. Observable state for the
//                                voice session: status, transcript, last error.
// VoiceSessionStatus          — `State/VoiceSessionStatus.swift`. .idle / .connecting /
//                                .listening / .speaking / .failed(reason).
// VoiceSessionFailureReason   — `State/VoiceSessionStatus.swift`. Why the session failed
//                                (permissionDenied, network, server, ...).

// MARK: - Services
//
// RealtimeVoiceSession        — `Service/RealtimeVoiceSession.swift`. Actor. The session
//                                lifecycle: start -> connect -> stream -> stop.
// RealtimeAPIAdapter          — `Service/RealtimeAPIAdapter.swift`. RealtimeClientAPI built
//                                on OpenAI's Realtime SDK. The app injects this in prod.
// EphemeralKeyFetcher         — `Service/EphemeralKeyFetcher.swift`. Actor. Mints short-lived
//                                Realtime keys via the Worker.
// VoiceTranscriptBridge       — `Service/VoiceTranscriptBridge.swift`. Actor. Forwards voice
//                                transcripts into the chat conversation as Message rows.

// MARK: - Protocols
//
// RealtimeClientAPI           — `Service/RealtimeClientAPI.swift`. The transport seam.
//                                Tests use a fake; the app uses RealtimeAPIAdapter.
// EphemeralKeyFetching        — `Service/EphemeralKeyFetcher.swift`. Protocol seam for tests.
// VoiceTranscriptDirtyHook    — `Service/VoiceTranscriptBridge.swift`. Lets the bridge tell
//                                the sync engine that new transcript messages exist.
// NoopVoiceTranscriptDirtyHook — `Service/VoiceTranscriptBridge.swift`. Default no-op
//                                implementation for tests/dev.
// MicPermissionGate           — `Permissions/MicPermissionGate.swift`. Async permission probe.
// AudioApplicationProbing     — `Permissions/SystemMicPermissionGate.swift`. The underlying
//                                AVAudioApplication probe seam.

// MARK: - Permissions
//
// MicPermissionDecision       — `Permissions/MicPermissionGate.swift`. .granted / .denied /
//                                .undetermined.
// SystemMicPermissionGate     — `Permissions/SystemMicPermissionGate.swift`. The real gate
//                                wrapping AVAudioApplication.
// SystemAudioApplicationProbe — `Permissions/SystemMicPermissionGate.swift`. The real
//                                AVAudioApplication probe.

// MARK: - Models / Types
//
// RealtimeConnectionStatus    — `Service/RealtimeClientAPI.swift`. Connection lifecycle enum.
// TranscriptRole              — `Service/RealtimeClientAPI.swift`. .user / .assistant.
// RealtimeTranscriptEvent     — `Service/RealtimeClientAPI.swift`. A single transcript delta.
// RealtimeClientError         — `Service/RealtimeClientAPI.swift`. Error wrapper for the client.
// EphemeralKey                — `Service/EphemeralKeyFetcher.swift`. Short-lived realtime key.

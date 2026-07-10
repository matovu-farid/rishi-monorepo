// RishiAudio — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiAudio exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiAudio is text-to-speech ("Read aloud") plus the underlying
// AVAudioEngine / AVAudioSession plumbing. It also owns the Now
// Playing info and remote-command center wiring.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 2 unused exports).

// MARK: - Views
//
// ReadAloudControlsView       — `UI/ReadAloudControlsView.swift`. The Read-aloud control bar
//                                (play/pause, skip, voice picker, speed slider).
// VoiceAndSpeedPicker         — `UI/VoiceAndSpeedPicker.swift`. Sheet picking a voice + speed.

// MARK: - TTS engine
//
// TTSEngine                   — `TTS/TTSEngine.swift`. Actor. The top-level Read-aloud
//                                state machine the UI binds to.
// TTSStreamer                 — `TTS/TTSStreamer.swift`. Actor. Pulls MP3 chunks from the
//                                Worker and feeds them into the decoder.
// MP3StreamDecoder            — `TTS/MP3StreamDecoder.swift`. Actor. Decodes MP3 chunks
//                                into PCM buffers.
// TTSPassageTracker           — `TTS/TTSPassageTracker.swift`. Actor. Tracks which sentence
//                                is currently spoken so the UI can highlight it.
// TTSPlaybackState            — `TTS/TTSPlaybackState.swift`. Observable playback state.
// TTSStatus                   — `TTS/TTSPlaybackState.swift`. .idle / .buffering / .playing /
//                                .paused / .failed.
// TTSStreamRequest            — `TTS/TTSStreamRequest.swift`. The request value the streamer
//                                sends to the Worker.
// TTSStreamerError            — `TTS/TTSStreamer.swift`. Errors raised by the streamer.
// PCMChunk                    — `TTS/PCMChunk.swift`. A single decoded PCM buffer.
// TTSChunkSource              — `TTS/TTSStreamer.swift`. Protocol seam: how chunks are fetched.
// WorkerTTSChunkSource        — `TTS/TTSStreamer.swift`. The production source (WorkerClient).
// FakeTTSChunkSource          — `TTS/TTSStreamer.swift`. Test-only deterministic source.

// MARK: - Audio engine protocols
//
// AudioEngineProtocol         — `TTS/AudioEngineProtocol.swift`. Seam over AVAudioEngine.
// AVAudioEngineAdapter        — `TTS/AudioEngineProtocol.swift`. Production adapter.
// FakeAudioEngine             — `TTS/AudioEngineProtocol.swift`. Test-only fake.

// MARK: - Now Playing
//
// NowPlayingController        — `TTS/NowPlayingController.swift`. Wires TTSPlaybackState into
//                                MPNowPlayingInfoCenter + MPRemoteCommandCenter.
// TTSPlaybackControlling      — `TTS/NowPlayingController.swift`. The play/pause/skip seam
//                                the controller exposes to the remote-command center.
// NowPlayingInfoSurface       — `TTS/NowPlayingProtocol.swift`. Seam over MPNowPlayingInfoCenter.
// RemoteCommandSurface        — `TTS/NowPlayingProtocol.swift`. Seam over MPRemoteCommandCenter.
// MPNowPlayingInfoCenterAdapter — `TTS/NowPlayingProtocol.swift`. Production adapter.
// MPRemoteCommandCenterAdapter  — `TTS/NowPlayingProtocol.swift`. Production adapter.
// FakeNowPlayingInfoSurface   — `TTS/NowPlayingProtocol.swift`. Test fake.
// FakeRemoteCommandSurface    — `TTS/NowPlayingProtocol.swift`. Test fake.
// NowPlayingMetadata          — `TTS/NowPlayingMetadata.swift`. The title/author/artwork the
//                                lock-screen shows.
// RemoteCommand               — `TTS/NowPlayingMetadata.swift`. Enum: .play / .pause /
//                                .skipForward / etc.
// RemoteCommandHandlers       — `TTS/NowPlayingMetadata.swift`. Bag of closures wired to
//                                MPRemoteCommandCenter.

// MARK: - Audio session
//
// AudioSessionCoordinator     — `Coordinator/AudioSessionCoordinator.swift`. Actor. Single
//                                owner of AVAudioSession activation/deactivation across TTS
//                                and voice chat.
// AudioSessionConfigurator    — `Coordinator/AudioSessionConfigurator.swift`. Protocol.
// AVAudioSessionConfigurator  — `Coordinator/AudioSessionConfigurator.swift`. Production
//                                AVAudioSession wrapper.
// FakeAudioSessionConfigurator — `Coordinator/AudioSessionConfigurator.swift`. Test fake.
// AudioSessionCategory        — `Coordinator/AudioSessionConfigurator.swift`. AVAudioSession
//                                category as a Sendable enum.
// AudioSessionMode            — `Coordinator/AudioSessionConfigurator.swift`. Mode enum.
// AudioSessionOptions         — `Coordinator/AudioSessionConfigurator.swift`. OptionSet
//                                wrapping AVAudioSession.CategoryOptions.
// AudioInterruptionEvent      — `Coordinator/AudioSessionConfigurator.swift`. .began / .ended.
// ActiveMode                  — `Coordinator/ActiveMode.swift`. Which subsystem currently
//                                holds the audio session: .none / .tts / .voice.

// MARK: - Settings
//
// TTSSettings                 — `Settings/TTSSettings.swift`. Voice id + speed + auto-pause.
// TTSSettingsStore            — `Settings/TTSSettingsStore.swift`. Protocol over the settings.
// UserDefaultsTTSSettingsStore — `Settings/TTSSettingsStore.swift`. Production store.
// InMemoryTTSSettingsStore    — `Settings/TTSSettingsStore.swift`. Test-only store.
// VoiceCatalog                — `UI/VoiceCatalog.swift`. The hard-coded list of available
//                                reader voice presets the picker shows.

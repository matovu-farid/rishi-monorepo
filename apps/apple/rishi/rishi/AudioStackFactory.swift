//
//  AudioStackFactory.swift
//  rishi
//
//  Plan 34-14 SRP split — extracts the audio/TTS stack construction out of
//  `AppDependencies`. This is the single place the Read Aloud wiring
//  (session configurator, now-playing surfaces, cache store, streamer,
//  engine, prewarmer) changes. Behaviour-preserving move from
//  `AppDependencies.makeAudioStack` / `openAudioStack` — the construction
//  body, the `#if DEBUG` UITest fixture swap, and the `AudioStack` shape are
//  unchanged.
//

import Foundation
import OSLog
import RishiAPI
import RishiAudio
import RishiLogging

/// Bundle of audio services constructed together so the builder body stays
/// readable.
// `@unchecked Sendable` so this can flow back as the result of an
// `async let` child task in `ServiceGraphFactory` Wave A (the audio stack
// and the DB pool race each other off-main). The contained types are
// reference types already used across actor boundaries downstream;
// bundling them in this struct doesn't change those invariants.
struct AudioStack: @unchecked Sendable {
    let coordinator: AudioSessionCoordinator
    let state: TTSPlaybackState
    let engine: TTSEngine
    let settingsStore: any TTSSettingsStore
    let nowPlaying: NowPlayingController
    // Phase 24 plan 24-03 — prewarmer for paragraph read-ahead. Built
    // from the SAME `chunkSource` the engine streams from so warm
    // drains hit the same CachingTTSChunkSource the engine consults.
    let prewarmer: TTSPrewarmer
}

/// Constructs the audio/TTS stack. `nonisolated` static surface so the
/// off-main service-graph builder can call `make(...)` via `async let` in
/// Wave A; the heavy `makeAudioStack` body itself hops onto MainActor because
/// `AVAudioEngineAdapter` and the now-playing surfaces are MainActor-isolated.
enum AudioStackFactory {

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

    /// Wave A entry point — `nonisolated` so the child task can begin work on
    /// its own executor without bouncing to MainActor for the heavy phase.
    nonisolated static func make(
        workerClient: WorkerClient
    ) async -> AudioStack {
        let audioState = signposter.beginInterval("audio.ready")
        defer { signposter.endInterval("audio.ready", audioState) }
        return await MainActor.run {
            Self.makeAudioStack(workerClient: workerClient)
        }
    }

    @MainActor
    static func makeAudioStack(workerClient: WorkerClient) -> AudioStack {
        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(AVFAudio)
        let configurator: any AudioSessionConfigurator = AVAudioSessionConfigurator()
        #else
        let configurator: any AudioSessionConfigurator = FakeAudioSessionConfigurator()
        #endif

        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(MediaPlayer)
        let infoSurface: any NowPlayingInfoSurface = MPNowPlayingInfoCenterAdapter()
        let commandSurface: any RemoteCommandSurface = MPRemoteCommandCenterAdapter()
        #else
        let infoSurface: any NowPlayingInfoSurface = FakeNowPlayingInfoSurface()
        let commandSurface: any RemoteCommandSurface = FakeRemoteCommandSurface()
        #endif

        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let state = TTSPlaybackState()
        // Phase 22 plan 22-03 — wrap the production WorkerTTSChunkSource in
        // a CachingTTSChunkSource so repeat plays of the same (text, voice,
        // speed) on this device round-trip from local disk with zero network
        // and zero OpenAI cost. If the cache store init throws (e.g. caches
        // directory cannot be created), fall back to the bare upstream so a
        // broken cache never breaks TTS. The downstream
        // `TTSStreamer(source:)` keeps consuming `any TTSChunkSource`, so
        // the streamer + engine + lock-screen surface need no edit.
        let ttsUpstream = WorkerTTSChunkSource(client: workerClient)
        let ttsCacheStore: TTSAudioCacheStore?
        do {
            ttsCacheStore = try TTSAudioCacheStore()
        } catch {
            Log.event("tts.cache.init.failed", level: .error, data: ["error": "\(error)"])
            ttsCacheStore = nil
        }
        var chunkSource: any TTSChunkSource = ttsCacheStore.map { store in
            CachingTTSChunkSource(upstream: ttsUpstream, store: store)
        } ?? ttsUpstream
        // UITEST — swap in a deterministic, fixture-backed offline source so
        // Read Aloud renders real audio through the production AVAudioEngine
        // with no worker round-trip and no auth. DEBUG + `RISHI_UITEST=1`
        // only. See UITestSupport.swift.
        #if DEBUG
        if UITestBypass.isActive {
            if UITestBypass.latentCachedTTS,
               let store = try? TTSAudioCacheStore(
                   directory: FileManager.default.temporaryDirectory
                       .appendingPathComponent("uitest-tts-\(UUID().uuidString)", isDirectory: true)
               ) {
                // Faithful repro of the production path: a latent fixture
                // (simulated synthesis delay) behind a real cache, with a fresh
                // per-launch cache dir so each paragraph's first play actually
                // "synthesizes". Reproduces prewarm-vs-Next timing.
                chunkSource = CachingTTSChunkSource(
                    upstream: FixtureTTSChunkSource(synthDelay: UITestBypass.ttsSynthDelay),
                    store: store
                )
                Log.event("uitest.tts.source.latent_cached", level: .info)
            } else {
                chunkSource = FixtureTTSChunkSource()
                Log.event("uitest.tts.source.swapped", level: .info)
            }
        }
        #endif
        // Phase 24 plan 24-03 — prewarm next 3-5 paragraphs through the
        // same CachingTTSChunkSource the engine streams from. A miss
        // writes the MP3 to disk; a hit is a no-op. ReaderTTSBridge owns
        // the lockstep.
        let prewarmer = TTSPrewarmer(source: chunkSource)
        let streamer = TTSStreamer(source: chunkSource)
        let engineAdapter = AVAudioEngineAdapter()
        let engine = TTSEngine(
            streamer: streamer,
            decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
            engine: engineAdapter,
            coordinator: coordinator,
            state: state
        )
        let settingsStore = UserDefaultsTTSSettingsStore()
        let nowPlaying = NowPlayingController(
            infoSurface: infoSurface,
            commandSurface: commandSurface
        )
        return AudioStack(
            coordinator: coordinator,
            state: state,
            engine: engine,
            settingsStore: settingsStore,
            nowPlaying: nowPlaying,
            prewarmer: prewarmer
        )
    }
}

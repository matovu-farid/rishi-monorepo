import Foundation
import OSLog




struct AudioStack: @unchecked Sendable {
    let coordinator: AudioSessionCoordinator
    let state: TTSPlaybackState
    let engine: any TTSPlaying
    let settingsStore: any TTSSettingsStore
    let nowPlaying: NowPlayingController
    let presence: TTSPresenceController

    let prewarmer: TTSPrewarmer
}

enum AudioStackFactory {

    nonisolated private static let signposter = OSSignposter(
        subsystem: "org.fidexa.rishi",
        category: "cold-launch"
    )

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
            let configurator: any AudioSessionConfigurator =
                AVAudioSessionConfigurator()
        #else
            let configurator: any AudioSessionConfigurator =
                FakeAudioSessionConfigurator()
        #endif

        #if (os(iOS) || targetEnvironment(macCatalyst)) && canImport(MediaPlayer)
            let infoSurface: any NowPlayingInfoSurface =
                MPNowPlayingInfoCenterAdapter()
            let commandSurface: any RemoteCommandSurface =
                MPRemoteCommandCenterAdapter()
        #else
            let infoSurface: any NowPlayingInfoSurface =
                FakeNowPlayingInfoSurface()
            let commandSurface: any RemoteCommandSurface =
                FakeRemoteCommandSurface()
        #endif

        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let state = TTSPlaybackState()

        let ttsUpstream = WorkerTTSChunkSource(client: workerClient)
        let ttsCacheStore: TTSAudioCacheStore?
        do {
            ttsCacheStore = try TTSAudioCacheStore()
        } catch {
            Log.event(
                "tts.cache.init.failed",
                level: .error,
                data: ["error": "\(error)"]
            )
            ttsCacheStore = nil
        }
        let chunkSource: any TTSChunkSource =
            ttsCacheStore.map { store in
                CachingTTSChunkSource(upstream: ttsUpstream, store: store)
            } ?? ttsUpstream

        let prewarmer = TTSPrewarmer(source: chunkSource)
        let streamer = TTSStreamer(source: chunkSource)
        let engine = ChunkedAudioPlayerTTSEngine(streamer: streamer, state: state)
        let settingsStore = UserDefaultsTTSSettingsStore()
        let nowPlaying = NowPlayingController(
            infoSurface: infoSurface,
            commandSurface: commandSurface
        )
        let presenceStore = UserDefaultsTTSPresenceStore()
        let presence = TTSPresenceController(state: state, store: presenceStore)
        return AudioStack(
            coordinator: coordinator,
            state: state,
            engine: engine,
            settingsStore: settingsStore,
            nowPlaying: nowPlaying,
            presence: presence,
            prewarmer: prewarmer
        )
    }
}

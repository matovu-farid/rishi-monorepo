import Foundation
import RishiAudio

// MARK: - Audio / TTS forwarder accessors

extension AppDependencies {
    var audioCoordinator: AudioSessionCoordinator { services!.audioCoordinator }
    var ttsState: TTSPlaybackState { services!.ttsState }
    var ttsEngine: TTSEngine { services!.ttsEngine }
    var ttsSettingsStore: any TTSSettingsStore { services!.ttsSettingsStore }
    var nowPlayingController: NowPlayingController { services!.nowPlayingController }
    var ttsPrewarmer: TTSPrewarmer { services!.ttsPrewarmer }
}

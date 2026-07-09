import Foundation
import RishiAudio



extension AppDependencies {
    var audioCoordinator: AudioSessionCoordinator { services!.audioCoordinator }
    var ttsState: TTSPlaybackState { services!.ttsState }
    var ttsEngine: TTSEngine { services!.ttsEngine }
    var ttsSettingsStore: any TTSSettingsStore { services!.ttsSettingsStore }
    var nowPlayingController: NowPlayingController { services!.nowPlayingController }
    var ttsPresenceController: TTSPresenceController { services!.ttsPresenceController }
    var ttsPrewarmer: TTSPrewarmer { services!.ttsPrewarmer }
}

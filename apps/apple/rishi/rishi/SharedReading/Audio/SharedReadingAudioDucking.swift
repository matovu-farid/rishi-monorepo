import Foundation

enum SharedReadingAudioDucking {
    static func ttsVolume(isTTSPlaying: Bool, speakerUserId: String?) -> Float {
        isTTSPlaying && speakerUserId != nil ? 0.25 : 1
    }
}

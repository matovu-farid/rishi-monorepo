import AVFoundation
import Foundation

/// Detects whether the user spoke during the activation window and when
/// their utterance ends (hangover). Implementations may also accumulate
/// transcript text for Plan C text-turn fallback.
protocol SpeechVADMonitoring: AnyObject, Sendable {
    var everSpoke: Bool { get }
    var accumulatedTranscript: String? { get }
    func start() throws
    func stop()
    func process(buffer: AVAudioPCMBuffer)
    func waitForSpeechEnd(timeout: Duration) async
}

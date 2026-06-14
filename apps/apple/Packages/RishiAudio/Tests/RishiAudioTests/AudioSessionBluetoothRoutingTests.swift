import Testing
import Foundation
@testable import RishiAudio

/// The `.tts` path configures `.playback` with `.allowBluetooth`. On a real
/// device `AVAudioSession.setCategory(.playback, options: .allowBluetooth)`
/// throws paramErr (-50) because `.allowBluetooth` is the Hands-Free Profile,
/// which requires record capability. Device logs showed exactly that:
/// `audio.session.mode.failed ... Code=-50 mode=tts`. For output-only playback
/// the correct routing is A2DP. This locks the mapping rule (host-testable
/// without AVAudioSession, which is iOS-only).
@Suite("AudioSession bluetooth routing")
struct AudioSessionBluetoothRoutingTests {

    @Test("playback + allowBluetooth resolves to A2DP, never HFP")
    func playbackUsesA2DP() {
        #expect(bluetoothRouting(category: .playback, options: [.allowBluetooth]) == .a2dp)
    }

    @Test("playAndRecord + allowBluetooth resolves to HFP (record-capable)")
    func playAndRecordUsesHFP() {
        #expect(bluetoothRouting(category: .playAndRecord, options: [.allowBluetooth]) == .hfp)
    }

    @Test("no allowBluetooth resolves to none for both categories")
    func noBluetoothOptionResolvesNone() {
        #expect(bluetoothRouting(category: .playback, options: [.allowAirPlay]) == .none)
        #expect(bluetoothRouting(category: .playAndRecord, options: []) == .none)
    }
}

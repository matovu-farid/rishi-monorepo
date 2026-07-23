import AVFoundation
import Foundation
import Testing
import RishiCore
@testable import RishiVoice

@Suite("PCM24kConverter")
struct PCM24kConverterTests {

    @Test("48 kHz mono sine resamples to 24 kHz PCM16 with expected byte count")
    func resample48kTo24k() {
        let inputRate = 48_000.0
        let durationSeconds = 0.1
        let inputCount = Int(inputRate * durationSeconds)
        let samples = (0..<inputCount).map { i in
            sin(2 * Double.pi * 440 * Double(i) / inputRate)
        }.map(Float.init)

        let pcm = PCM24kConverter.convert(samples: samples, sampleRate: inputRate)
        let expectedSamples = Int(PCM24kConverter.targetSampleRate * durationSeconds)
        #expect(pcm.count == expectedSamples * 2)
    }

    @Test("empty input yields empty output")
    func emptyInput() {
        #expect(PCM24kConverter.convert(samples: [], sampleRate: 48_000).isEmpty)
    }
}

@Suite("EnergyVADMonitor")
struct EnergyVADMonitorTests {

    @Test("everSpoke survives stop — handoff reads state before reset")
    func everSpokeSurvivesStop() {
        let vad = EnergyVADMonitor(hangoverMs: 700)
        let buffer = Self.loudPCMBuffer()
        vad.process(buffer: buffer)
        #expect(vad.everSpoke)
        vad.stop()
        #expect(vad.everSpoke)
    }

    private static func loudPCMBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        buffer.frameLength = 2048
        for i in 0..<2048 {
            buffer.floatChannelData![0][i] = 0.5
        }
        return buffer
    }
}

@Suite("VoiceActivationCoordinator")
struct VoiceActivationCoordinatorTests {

    private actor StopCompletion {
        private(set) var didStop = false

        func markStopped() {
            didStop = true
        }
    }

    private final class HandoffTrackingClient: RealtimeClientAPI, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var micEnabled = false
        private(set) var assistantOutputEnabled = false
        private(set) var injectedAudioCount = 0
        private(set) var injectedText: [String] = []
        var injectAudioResult: HandoffAcceptance = .accepted(path: .path0A)
        var injectTextResult: HandoffAcceptance = .accepted(path: .path0C)

        func connect(
            ephemeralKey: String,
            bookContext: BookContextSnapshot?,
            language: String?,
            deferMicCapture: Bool
        ) async throws {}

        func disconnect() async {}
        func currentStatus() async -> RealtimeConnectionStatus { .connected }
        var providerCallId: String? { nil }
        func errorStream() -> AsyncStream<RealtimeClientError> { AsyncStream { $0.finish() } }
        func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> { AsyncStream { $0.finish() } }
        func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> { AsyncStream { $0.finish() } }
        func sendToolResult(callId: String, payload: String) async throws {}

        func setMicCaptureEnabled(_ enabled: Bool) async {
            lock.withLock { micEnabled = enabled }
        }

        func setAssistantOutputEnabled(_ enabled: Bool) async {
            lock.withLock { assistantOutputEnabled = enabled }
        }

        func cancelCurrentResponse() async {}

        func injectBufferedInputAudio(_ pcm16le24kMono: Data) async throws -> HandoffAcceptance {
            lock.withLock { injectedAudioCount += 1 }
            return injectAudioResult
        }

        func injectBufferedInputText(_ text: String) async throws -> HandoffAcceptance {
            lock.withLock { injectedText.append(text) }
            return injectTextResult
        }
    }

    @Test("completeHandoff without begin enables mic and skips inject")
    func handoffWithoutActivation() async throws {
        let client = HandoffTrackingClient()
        let coordinator = VoiceActivationCoordinator()
        let outcome = try await coordinator.completeHandoff(client: client)
        #expect(outcome == .liveMicOnly)
        #expect(client.micEnabled)
        #expect(client.assistantOutputEnabled)
        #expect(client.injectedAudioCount == 0)
    }

    @Test("speech VAD stop completes without deadlocking")
    func speechVADStopDoesNotDeadlock() async {
        let monitor = SpeechVADMonitor(hangoverMs: 700)
        let completion = StopCompletion()
        let stopTask = Task.detached {
            monitor.stop()
            await completion.markStopped()
        }

        try? await Task.sleep(for: .milliseconds(500))
        #expect(await completion.didStop)
        stopTask.cancel()
    }
}

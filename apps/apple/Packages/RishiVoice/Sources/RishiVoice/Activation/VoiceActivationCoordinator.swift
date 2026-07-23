import AVFoundation
import Foundation
import RishiLogging
import Speech

/// Presenter-owned activation lifecycle: local record + VAD during connect,
/// PCM inject + live mic handoff when the Realtime session is ready.
public protocol VoiceActivationCoordinating: Sendable {
    var currentActivationID: ActivationID? { get async }
    func beginActivation() async
    func completeHandoff(client: any RealtimeClientAPI) async throws -> HandoffOutcome
    func cancel() async
}

public actor VoiceActivationCoordinator: VoiceActivationCoordinating {

    private let config: VoiceActivationConfig
    private var activationID: ActivationID?
    private(set) var state: ActivationState = .idle
    private var recorder: ActivationAudioRecorder?
    private var energyVAD: EnergyVADMonitor?
    private var speechVAD: SpeechVADMonitor?
    private let feedBridge = VADFeedBridge()
    private var speechAttachTask: Task<Void, Never>?
    private var isActive = false

    public init(config: VoiceActivationConfig = .default) {
        self.config = config
    }

    public var currentActivationID: ActivationID? { activationID }

    public func beginActivation() async {
        guard !isActive else { return }
        let id = ActivationID()
        activationID = id
        isActive = true
        state = .capturing

        let energy = EnergyVADMonitor(hangoverMs: config.hangoverMs)
        energyVAD = energy
        feedBridge.attach(energy: energy)

        let recorder = ActivationAudioRecorder(maxBufferSeconds: config.maxBufferSeconds)
        self.recorder = recorder

        // Recorder starts immediately — never blocked on Speech authorization.
        do {
            try recorder.start { [feedBridge] buffer in
                feedBridge.process(buffer: buffer)
            }
        } catch {
            Log.event("voice.activation.recorder.failed", level: .error)
            await cancel()
            return
        }

        speechAttachTask = Task { [weak self] in
            await self?.attachSpeechMonitorIfPossible(for: id)
        }
    }

    public func completeHandoff(client: any RealtimeClientAPI) async throws -> HandoffOutcome {
        guard isActive, let id = activationID, let energy = energyVAD, let recorder else {
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .liveMicOnly
        }

        speechAttachTask?.cancel()
        speechAttachTask = nil
        state = .waitingForSilence

        let spoke = energy.everSpoke || (speechVAD?.everSpoke ?? false)
        let fallbackTranscript = speechVAD?.accumulatedTranscript

        if spoke {
            let silenceTimeout = Duration.milliseconds(config.silenceBoundaryTimeoutMs)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await energy.waitForSpeechEnd(timeout: silenceTimeout)
                }
                if let speech = speechVAD {
                    group.addTask {
                        await speech.waitForSpeechEnd(timeout: silenceTimeout)
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }

        guard isActive, activationID == id else { return .interrupted }

        recorder.stop()
        speechVAD?.stop()
        energy.stop()

        try? await Task.sleep(for: .milliseconds(250))

        guard isActive, activationID == id else { return .interrupted }

        let snapshot = recorder.snapshot()
        await teardownActivationState()

        if !spoke || snapshot.samples.isEmpty {
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .liveMicOnly
        }

        state = .injecting
        let pcm = PCM24kConverter.convert(
            samples: snapshot.samples,
            sampleRate: snapshot.sampleRate
        )

        guard !pcm.isEmpty else {
            if let text = fallbackTranscript, !text.isEmpty {
                return try await injectTextFallback(text, client: client)
            }
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .recoveredLiveMic(notice: HandoffOutcome.missedUtteranceNotice)
        }

        state = .armingLiveMic
        let acceptance = try await client.injectBufferedInputAudio(pcm)
        switch acceptance {
        case .accepted(let path):
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            state = .live
            Log.event("voice.activation.handoff.accepted", level: .info, data: [
                "activationId": id.rawValue.uuidString,
                "path": path.rawValue,
                "bufferBytes": String(pcm.count),
            ])
            return .accepted(path: path)

        case .rejected(let path, let code):
            Log.event("voice.activation.handoff.rejected", level: .warning, data: [
                "activationId": id.rawValue.uuidString,
                "path": path.rawValue,
                "code": code,
            ])
            if let text = fallbackTranscript, !text.isEmpty {
                return try await injectTextFallback(text, client: client)
            }
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .recoveredLiveMic(notice: HandoffOutcome.missedUtteranceNotice)

        case .ambiguous:
            Log.event("voice.activation.handoff.ambiguous", level: .warning, data: [
                "activationId": id.rawValue.uuidString,
            ])
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .recoveredLiveMic(notice: HandoffOutcome.missedUtteranceNotice)

        case .noSpeech:
            await client.setMicCaptureEnabled(true)
            await client.setAssistantOutputEnabled(true)
            return .liveMicOnly
        }
    }

    public func cancel() async {
        speechAttachTask?.cancel()
        speechAttachTask = nil
        recorder?.stop()
        speechVAD?.stop()
        energyVAD?.stop()
        feedBridge.attachSpeech(nil)
        await teardownActivationState()
    }

    // MARK: - Private

    private func attachSpeechMonitorIfPossible(for id: ActivationID) async {
        let status = await Self.requestSpeechAuthorization()
        guard isActive, activationID == id else { return }
        guard status == .authorized else {
            Log.event("voice.activation.speech.denied", level: .info)
            return
        }

        let speech = SpeechVADMonitor(hangoverMs: config.hangoverMs)
        do {
            try speech.start()
        } catch {
            Log.event("voice.activation.speech.unavailable", level: .info)
            return
        }

        guard isActive, activationID == id else {
            speech.stop()
            return
        }

        speechVAD = speech
        feedBridge.attachSpeech(speech)
        Log.event("voice.activation.speech.attached", level: .info)
    }

    private func injectTextFallback(
        _ text: String,
        client: any RealtimeClientAPI
    ) async throws -> HandoffOutcome {
        let acceptance = try await client.injectBufferedInputText(text)
        await client.setMicCaptureEnabled(true)
        await client.setAssistantOutputEnabled(true)
        state = .live
        switch acceptance {
        case .accepted:
            return .accepted(path: .path0C)
        case .rejected(_, let code):
            Log.event("voice.activation.text.rejected", level: .warning, data: ["code": code])
            return .recoveredLiveMic(notice: HandoffOutcome.missedUtteranceNotice)
        case .ambiguous:
            return .recoveredLiveMic(notice: HandoffOutcome.missedUtteranceNotice)
        case .noSpeech:
            return .liveMicOnly
        }
    }

    private func teardownActivationState() async {
        recorder = nil
        speechVAD = nil
        energyVAD = nil
        feedBridge.attachSpeech(nil)
        activationID = nil
        isActive = false
        state = .cancelled
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

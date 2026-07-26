import AVFoundation
import Foundation
import Speech

/// On-device speech recognition used as VAD during activation. Transcript
/// text is accumulated for Plan C fallback but not used for the primary path.
final class SpeechVADMonitor: SpeechVADMonitoring, @unchecked Sendable {

    private let lock = NSLock()
    private let hangoverMs: Int
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var _everSpoke = false
    private var _accumulatedTranscript = ""
    private var lastSpeechAt: ContinuousClock.Instant?
    private var speechEndedContinuation: CheckedContinuation<Void, Never>?

    var everSpoke: Bool { lock.withLock { _everSpoke } }

    var accumulatedTranscript: String? {
        let text = lock.withLock { _accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.isEmpty ? nil : text
    }

    init(hangoverMs: Int, locale: Locale = Locale(identifier: "en-US")) {
        self.hangoverMs = hangoverMs
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechVADError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        lock.withLock {
            self.request = request
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if error != nil {
                    self.signalSpeechEndedIfWaiting()
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                var continuation: CheckedContinuation<Void, Never>?
                self.lock.withLock {
                    if !text.isEmpty {
                        self._everSpoke = true
                        self._accumulatedTranscript = text
                        self.lastSpeechAt = ContinuousClock.now
                    }
                    if result.isFinal {
                        continuation = self.speechEndedContinuation
                        self.speechEndedContinuation = nil
                    }
                }
                continuation?.resume()
            }
        }
    }

    /// Stops recognition without clearing `everSpoke` — read speech state before calling.
    func stop() {
        let (recognitionTask, audioRequest, continuation) = lock.withLock {
            let recognitionTask = task
            let audioRequest = request
            let continuation = speechEndedContinuation
            task = nil
            request = nil
            speechEndedContinuation = nil
            return (recognitionTask, audioRequest, continuation)
        }
        recognitionTask?.cancel()
        audioRequest?.endAudio()
        continuation?.resume()
    }

    func process(buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    func waitForSpeechEnd(timeout: Duration) async {
        let needsWait: Bool = lock.withLock {
            guard _everSpoke, let lastSpeechAt else { return false }
            return (ContinuousClock.now - lastSpeechAt) < .milliseconds(hangoverMs)
        }
        guard needsWait else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let shouldInstall: Bool = self.lock.withLock {
                        guard self._everSpoke, let last = self.lastSpeechAt else { return false }
                        if (ContinuousClock.now - last) >= .milliseconds(self.hangoverMs) {
                            return false
                        }
                        self.speechEndedContinuation = continuation
                        return true
                    }
                    if !shouldInstall {
                        continuation.resume()
                    }
                }
            }
            group.addTask {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: timeout)
                while clock.now < deadline {
                    let silent: Bool = self.lock.withLock {
                        guard self._everSpoke, let last = self.lastSpeechAt else { return true }
                        return (ContinuousClock.now - last) >= .milliseconds(self.hangoverMs)
                    }
                    if silent {
                        self.signalSpeechEndedIfWaiting()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.signalSpeechEndedIfWaiting()
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func signalSpeechEndedIfWaiting() {
        let continuation = lock.withLock {
            let continuation = speechEndedContinuation
            speechEndedContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

enum SpeechVADError: Error {
    case recognizerUnavailable
}

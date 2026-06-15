import Foundation

/// Decides when a streamed playback's completion stream may finish.
///
/// `AVAudioPlayerNode` schedules buffers and invokes a completion handler when
/// each finishes rendering — asynchronously, AFTER scheduling. The output
/// AsyncStream must stay open until BOTH the input buffer sequence has ended
/// AND every scheduled buffer's completion has fired. Finishing as soon as the
/// input ends (the previous behaviour) drops the still-pending completions —
/// including the final one — so `TTSEngine.onBufferComplete(isFinal:)` never
/// runs, `.stopped` is never set, and read-aloud does not auto-advance.
/// Counts are mutated under the adapter's lock.
struct PlaybackCompletionAccountant {
    private var scheduled = 0
    private var completed = 0
    private var inputEnded = false

    /// Record that a buffer was scheduled on the player node.
    mutating func didSchedule() { scheduled += 1 }

    /// Record a buffer-completion callback. Returns true if the output stream
    /// should finish now (input ended AND all scheduled buffers completed).
    mutating func didComplete() -> Bool {
        completed += 1
        return shouldFinish
    }

    /// Record that the input buffer sequence ended. Returns true if the output
    /// stream should finish immediately (all scheduled buffers already done).
    mutating func didEndInput() -> Bool {
        inputEnded = true
        return shouldFinish
    }

    private var shouldFinish: Bool { inputEnded && completed >= scheduled }
}

/// Reference box so the audio render thread's completion handlers and the
/// scheduling loop can share one `PlaybackCompletionAccountant`. Access is
/// serialised externally through the adapter's lock.
final class AccountantBox: @unchecked Sendable {
    var value = PlaybackCompletionAccountant()
}

#if canImport(AVFAudio)
import AVFAudio

/// Injection seam for AVAudioEngine + AVAudioPlayerNode pair. Production
/// wires AVAudioEngineAdapter; tests wire FakeAudioEngine.
///
/// `Sendable` requirement holds because both impls serialise mutation
/// through their own internal locks/main-actor isolation.
public protocol AudioEngineProtocol: Sendable {
    var targetFormat: AVAudioFormat { get }
    var isPlaying: Bool { get }
    func attach() throws
    func start() throws
    func stop()
    /// Reset the player node for a new passage WITHOUT stopping the engine or
    /// touching the audio route/session. Used by the long-lived-engine path so a
    /// passage switch flushes the previous passage's scheduled buffers and is
    /// ready to schedule the next one's, while attach/start/stop happen only
    /// once per read-aloud session.
    func resetPlayerNode()
    func play<S: AsyncSequence>(_ buffers: S) -> AsyncStream<PCMChunk.ID>
        where S.Element == PCMChunk, S: Sendable
    func pause()
    func resume()
}

// MARK: - Production

#if os(iOS) || targetEnvironment(macCatalyst) || os(macOS)

/// Wraps the real AVAudioEngine + AVAudioPlayerNode pair. Attaches the player
/// node on init; targetFormat is read live from the engine's main mixer (so
/// callers can construct the decoder against the canonical format).
///
/// `@unchecked Sendable` because AVAudioEngine + AVAudioPlayerNode are
/// non-Sendable Obj-C reference types; the adapter serialises mutation through
/// `NSLock` so concurrent calls from TTSEngine's actor isolation cannot
/// produce races.
public final class AVAudioEngineAdapter: AudioEngineProtocol, @unchecked Sendable {

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let lock = NSLock()

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
    }

    public var targetFormat: AVAudioFormat {
        engine.mainMixerNode.outputFormat(forBus: 0)
    }

    public var isPlaying: Bool {
        lock.withLock { playerNode.isPlaying }
    }

    public func attach() throws {
        lock.withLock {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        }
    }

    public func start() throws {
        try lock.withLock {
            if !engine.isRunning { try engine.start() }
        }
    }

    public func stop() {
        lock.withLock {
            playerNode.stop()
            if engine.isRunning { engine.stop() }
        }
    }

    public func resetPlayerNode() {
        // Engine stays running; only the player node is reset so the next
        // passage's buffers schedule onto a clean node. Route/session untouched.
        lock.withLock {
            playerNode.stop()
            playerNode.reset()
        }
    }

    public func play<S: AsyncSequence>(_ buffers: S) -> AsyncStream<PCMChunk.ID>
    where S.Element == PCMChunk, S: Sendable {
        AsyncStream { continuation in
            // Track scheduled-vs-completed buffers so the stream stays open
            // until the LAST buffer has rendered. Boxed because the completion
            // handlers (audio render thread) and the scheduling loop both mutate
            // it; all access is serialised through `self.lock`.
            let box = AccountantBox()
            let task = Task { [self] in
                do {
                    for try await chunk in buffers {
                        if Task.isCancelled { break }
                        let id = chunk.id
                        self.lock.withLock {
                            box.value.didSchedule()
                            self.playerNode.scheduleBuffer(chunk.buffer) {
                                let shouldFinish = self.lock.withLock { box.value.didComplete() }
                                continuation.yield(id)
                                if shouldFinish { continuation.finish() }
                            }
                        }
                    }
                    // Input ended. Finish only if every scheduled buffer has
                    // already completed; otherwise the last didComplete() will.
                    let shouldFinish = self.lock.withLock { box.value.didEndInput() }
                    if shouldFinish { continuation.finish() }
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func resume() {
        lock.withLock {
            if !playerNode.isPlaying { playerNode.play() }
        }
    }

    public func pause() {
        lock.withLock { playerNode.pause() }
    }

    // MARK: - Test seam (offline manual rendering)
    //
    // The real adapter owns a real-time AVAudioEngine, so audio output can't be
    // observed in a unit test without hardware. These helpers put the SAME
    // engine into offline manual-rendering mode so a test can pull rendered
    // frames and assert the playerNode actually produces audio — including after
    // a mid-stream stop() (the next/prev path that auto-advance never hits).

    func enableOfflineRendering(format: AVAudioFormat, maximumFrameCount: AVAudioFrameCount) throws {
        try lock.withLock {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
        }
    }

    func renderOffline(_ frameCount: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try lock.withLock {
            try engine.renderOffline(frameCount, to: buffer)
        }
    }

    var manualRenderingFormat: AVAudioFormat {
        lock.withLock { engine.manualRenderingFormat }
    }
}

#endif

// MARK: - Fake (test helper, ships in main target)

/// Test-only AudioEngineProtocol impl. Records every call in order and fires
/// scheduled-buffer completion handlers synchronously so tests can assert
/// first-buffer side-effects without sleeping for a real audio render cycle.
/// @unchecked Sendable justified: test fake with mutable `var _calls` and
/// `var _isPlaying` guarded by an internal NSLock.
public final class FakeAudioEngine: AudioEngineProtocol, @unchecked Sendable {

    public enum Call: Sendable, Equatable {
        case attach
        case start
        case stop
        case resetNode
        case playStarted
        case chunkSeen(id: UUID, passageId: String?, isFinal: Bool)
        case completionEmitted(id: UUID)
        case pause
        case resume
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _isPlaying = false
    public let targetFormat: AVAudioFormat

    public init(targetFormat: AVAudioFormat? = nil) {
        self.targetFormat = targetFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
    }

    public var isPlaying: Bool { lock.withLock { _isPlaying } }
    public var calls: [Call] { lock.withLock { _calls } }

    public func attach() throws {
        lock.withLock { _calls.append(.attach) }
    }

    public func start() throws {
        lock.withLock { _calls.append(.start) }
    }

    public func stop() {
        lock.withLock {
            _calls.append(.stop)
            _isPlaying = false
        }
    }

    public func resetPlayerNode() {
        // Records ONLY .resetNode — never .stop/.attach/.start — so the
        // long-lived-engine detector can assert a switch does not churn.
        lock.withLock { _calls.append(.resetNode) }
    }

    public func play<S: AsyncSequence>(_ buffers: S) -> AsyncStream<PCMChunk.ID>
    where S.Element == PCMChunk, S: Sendable {
        lock.withLock { _calls.append(.playStarted) }
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                do {
                    for try await chunk in buffers {
                        if Task.isCancelled { break }
                        let id = chunk.id
                        let passageId = chunk.passageId
                        let isFinal = chunk.isFinal
                        self?.lock.withLock {
                            self?._calls.append(.chunkSeen(id: id, passageId: passageId, isFinal: isFinal))
                        }
                        continuation.yield(id)
                        self?.lock.withLock {
                            self?._calls.append(.completionEmitted(id: id))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pause() {
        lock.withLock {
            _calls.append(.pause)
            _isPlaying = false
        }
    }

    public func resume() {
        lock.withLock {
            _calls.append(.resume)
            _isPlaying = true
        }
    }
}

#endif

import Foundation
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
    func schedule(buffer: PCMChunk, completion: @Sendable @escaping () -> Void)
    func play()
    func pause()
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

    public func schedule(buffer: PCMChunk, completion: @Sendable @escaping () -> Void) {
        lock.withLock {
            playerNode.scheduleBuffer(buffer.buffer, completionHandler: completion)
        }
    }

    public func play() {
        lock.withLock {
            if !playerNode.isPlaying { playerNode.play() }
        }
    }

    public func pause() {
        lock.withLock { playerNode.pause() }
    }
}

#endif

// MARK: - Fake (test helper, ships in main target)

/// Test-only AudioEngineProtocol impl. Records every call in order and fires
/// scheduled-buffer completion handlers synchronously so tests can assert
/// first-buffer side-effects without sleeping for a real audio render cycle.
public final class FakeAudioEngine: AudioEngineProtocol, @unchecked Sendable {

    public enum Call: Sendable, Equatable {
        case attach
        case start
        case stop
        case schedule(passageId: String?, isFinal: Bool)
        case play
        case pause
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

    public func schedule(buffer: PCMChunk, completion: @Sendable @escaping () -> Void) {
        lock.withLock { _calls.append(.schedule(passageId: buffer.passageId, isFinal: buffer.isFinal)) }
        // Fire completion synchronously so tests can observe first-buffer effects without a delay.
        completion()
    }

    public func play() {
        lock.withLock {
            _calls.append(.play)
            _isPlaying = true
        }
    }

    public func pause() {
        lock.withLock {
            _calls.append(.pause)
            _isPlaying = false
        }
    }
}

#endif

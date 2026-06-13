import Foundation

// MARK: - Sendable mirror types

/// Subset of AVAudioSession.Category we use in v1. Mirrored as a Sendable
/// enum so AudioSessionCoordinator (an actor) and FakeAudioSessionConfigurator
/// (a test helper) can speak the same shape without dragging AVFAudio into
/// every test target.
public enum AudioSessionCategory: String, Sendable, Equatable, CaseIterable {
    case playback        // TTS
    case playAndRecord   // Voice chat (Phase 10)
}

public enum AudioSessionMode: String, Sendable, Equatable, CaseIterable {
    case spokenAudio
    case voiceChat
}

public struct AudioSessionOptions: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let allowBluetooth   = AudioSessionOptions(rawValue: 1 << 0)
    public static let allowAirPlay     = AudioSessionOptions(rawValue: 1 << 1)
    public static let defaultToSpeaker = AudioSessionOptions(rawValue: 1 << 2)
}

public enum AudioInterruptionEvent: Sendable, Equatable {
    case began
    case endedShouldResume
    case endedNoResume
}

// MARK: - Protocol

/// Injection seam for AVAudioSession. Production wires
/// `AVAudioSessionConfigurator`; tests wire `FakeAudioSessionConfigurator`.
public protocol AudioSessionConfigurator: Sendable {
    func configure(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: AudioSessionOptions
    ) throws

    func setActive(_ active: Bool, notifyOthers: Bool) throws

    /// One-shot interruption stream. Coordinator subscribes on init; closes
    /// when the configurator is deallocated.
    func interruptionStream() -> AsyncStream<AudioInterruptionEvent>
}

// MARK: - Production impl

#if canImport(AVFAudio) && (os(iOS) || targetEnvironment(macCatalyst))
import AVFAudio

/// @unchecked Sendable justified: wraps a non-Sendable `AVAudioSession` and
/// an `NSObjectProtocol` notification-observer token. The session is the
/// process-wide singleton (thread-safe by Apple's contract); the observer
/// token is set once at init and removed in deinit.
public final class AVAudioSessionConfigurator: AudioSessionConfigurator, @unchecked Sendable {

    private let session: AVAudioSession
    private let observerToken: NSObjectProtocol
    private let continuation: AsyncStream<AudioInterruptionEvent>.Continuation
    private let stream: AsyncStream<AudioInterruptionEvent>

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        var localContinuation: AsyncStream<AudioInterruptionEvent>.Continuation!
        self.stream = AsyncStream { localContinuation = $0 }
        self.continuation = localContinuation

        self.observerToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [continuation = localContinuation!] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                continuation.yield(.began)
            case .ended:
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                continuation.yield(opts.contains(.shouldResume) ? .endedShouldResume : .endedNoResume)
            @unknown default:
                break
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observerToken)
        continuation.finish()
    }

    public func configure(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: AudioSessionOptions
    ) throws {
        let avCategory: AVAudioSession.Category = (category == .playback) ? .playback : .playAndRecord
        let avMode: AVAudioSession.Mode = (mode == .spokenAudio) ? .spokenAudio : .voiceChat
        var avOptions: AVAudioSession.CategoryOptions = []
        if options.contains(.allowBluetooth)   { avOptions.insert(.allowBluetooth) }
        if options.contains(.allowAirPlay)     { avOptions.insert(.allowAirPlay) }
        if options.contains(.defaultToSpeaker) { avOptions.insert(.defaultToSpeaker) }
        try session.setCategory(avCategory, mode: avMode, options: avOptions)
    }

    public func setActive(_ active: Bool, notifyOthers: Bool) throws {
        try session.setActive(
            active,
            options: (active || !notifyOthers) ? [] : .notifyOthersOnDeactivation
        )
    }

    public func interruptionStream() -> AsyncStream<AudioInterruptionEvent> { stream }
}
#endif

// MARK: - Fake (test helper, ships in main target so XCTest-less smoke tests can use it)

/// @unchecked Sendable justified: test helper with mutable `var _configureCalls`
/// and `var _activeCalls` for assertion capture, guarded by an internal NSLock.
public final class FakeAudioSessionConfigurator: AudioSessionConfigurator, @unchecked Sendable {

    public struct ConfigureCall: Sendable, Equatable {
        public let category: AudioSessionCategory
        public let mode: AudioSessionMode
        public let options: AudioSessionOptions
    }

    public struct ActiveCall: Sendable, Equatable {
        public let active: Bool
        public let notifyOthers: Bool
    }

    private let lock = NSLock()
    private var _configureCalls: [ConfigureCall] = []
    private var _activeCalls: [ActiveCall] = []
    private let continuation: AsyncStream<AudioInterruptionEvent>.Continuation
    private let stream: AsyncStream<AudioInterruptionEvent>

    public init() {
        var local: AsyncStream<AudioInterruptionEvent>.Continuation!
        self.stream = AsyncStream { local = $0 }
        self.continuation = local
    }

    public func configure(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: AudioSessionOptions
    ) throws {
        lock.lock()
        _configureCalls.append(.init(category: category, mode: mode, options: options))
        lock.unlock()
    }

    public func setActive(_ active: Bool, notifyOthers: Bool) throws {
        lock.lock()
        _activeCalls.append(.init(active: active, notifyOthers: notifyOthers))
        lock.unlock()
    }

    public func interruptionStream() -> AsyncStream<AudioInterruptionEvent> { stream }

    /// Test seam — yield a synthetic interruption event into the stream.
    public func inject(_ event: AudioInterruptionEvent) {
        continuation.yield(event)
    }

    public var configureCalls: [ConfigureCall] {
        lock.lock()
        defer { lock.unlock() }
        return _configureCalls
    }

    public var activeCalls: [ActiveCall] {
        lock.lock()
        defer { lock.unlock() }
        return _activeCalls
    }
}

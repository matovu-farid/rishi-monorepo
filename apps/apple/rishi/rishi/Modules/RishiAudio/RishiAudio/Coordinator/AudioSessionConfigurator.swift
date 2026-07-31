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
    // Speakerphone-style duplex path. Same voice-processing audio unit as
    // .voiceChat (echo cancellation, two-way), but routes to the loud
    // built-in speaker instead of the quiet handset path.
    case videoChat
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

/// Significant output-route changes that can affect active narration.
///
/// The coordinator intentionally reacts only to `.oldDeviceUnavailable` for
/// now: unplugging headphones/AirPods must pause narration, while a new route
/// should not unexpectedly resume audio without an explicit user action.
public enum AudioRouteChangeEvent: Sendable, Equatable {
    case oldDeviceUnavailable
    case newDeviceAvailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRoute
    case unknown
}

/// How `.allowBluetooth` should be realised for a given category.
///
/// `.allowBluetooth` in our option set means "route to Bluetooth if available".
/// AVAudioSession splits this into two incompatible profiles:
///   - HFP (`.allowBluetooth`): bidirectional, REQUIRES a record-capable
///     category. Pairing it with `.playback` makes `setCategory` throw
///     paramErr (-50) — observed on device as `audio.session.mode.failed`.
///   - A2DP (`.allowBluetoothA2DP`): output-only, valid for playback.
/// Extracted as a pure function so the rule is testable without AVAudioSession
/// (which is iOS-only and absent under `swift test` on macOS).
public enum BluetoothRouting: String, Sendable, Equatable {
    case none
    case hfp
    case a2dp
}

public func bluetoothRouting(
    category: AudioSessionCategory,
    options: AudioSessionOptions
) -> BluetoothRouting {
    guard options.contains(.allowBluetooth) else { return .none }
    return category == .playAndRecord ? .hfp : .a2dp
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

    /// One-shot audio-route stream. Coordinator subscribes on init; closes
    /// when the configurator is deallocated.
    func routeChangeStream() -> AsyncStream<AudioRouteChangeEvent>
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
    private let routeObserverToken: NSObjectProtocol
    private let continuation: AsyncStream<AudioInterruptionEvent>.Continuation
    private let stream: AsyncStream<AudioInterruptionEvent>
    private let routeContinuation: AsyncStream<AudioRouteChangeEvent>.Continuation
    private let routeStream: AsyncStream<AudioRouteChangeEvent>

    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        var localContinuation: AsyncStream<AudioInterruptionEvent>.Continuation!
        self.stream = AsyncStream { localContinuation = $0 }
        self.continuation = localContinuation

        var localRouteContinuation: AsyncStream<AudioRouteChangeEvent>.Continuation!
        self.routeStream = AsyncStream { localRouteContinuation = $0 }
        self.routeContinuation = localRouteContinuation

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

        self.routeObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [routeContinuation = localRouteContinuation!] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            switch reason {
            case .oldDeviceUnavailable:
                routeContinuation.yield(.oldDeviceUnavailable)
            case .newDeviceAvailable:
                routeContinuation.yield(.newDeviceAvailable)
            case .categoryChange:
                routeContinuation.yield(.categoryChange)
            case .override:
                routeContinuation.yield(.override)
            case .wakeFromSleep:
                routeContinuation.yield(.wakeFromSleep)
            case .noSuitableRouteForCategory:
                routeContinuation.yield(.noSuitableRoute)
            case .unknown, .routeConfigurationChange:
                routeContinuation.yield(.unknown)
            @unknown default:
                routeContinuation.yield(.unknown)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observerToken)
        NotificationCenter.default.removeObserver(routeObserverToken)
        continuation.finish()
        routeContinuation.finish()
    }

    public func configure(
        category: AudioSessionCategory,
        mode: AudioSessionMode,
        options: AudioSessionOptions
    ) throws {
        let avCategory: AVAudioSession.Category = (category == .playback) ? .playback : .playAndRecord
        let avMode: AVAudioSession.Mode
        switch mode {
        case .spokenAudio: avMode = .spokenAudio
        case .voiceChat:   avMode = .voiceChat
        case .videoChat:   avMode = .videoChat
        }
        var avOptions: AVAudioSession.CategoryOptions = []
        // Map our generic `.allowBluetooth` to the profile valid for the
        // category. HFP (`.allowBluetooth`) with `.playback` throws -50; output
        // playback uses A2DP. See `bluetoothRouting`.
        switch bluetoothRouting(category: category, options: options) {
        case .none: break
        case .hfp:  avOptions.insert(.allowBluetooth)
        case .a2dp: avOptions.insert(.allowBluetoothA2DP)
        }
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

    public func routeChangeStream() -> AsyncStream<AudioRouteChangeEvent> { routeStream }
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
    private let routeContinuation: AsyncStream<AudioRouteChangeEvent>.Continuation
    private let routeStream: AsyncStream<AudioRouteChangeEvent>

    public init() {
        var local: AsyncStream<AudioInterruptionEvent>.Continuation!
        self.stream = AsyncStream { local = $0 }
        self.continuation = local
        var localRoute: AsyncStream<AudioRouteChangeEvent>.Continuation!
        self.routeStream = AsyncStream { localRoute = $0 }
        self.routeContinuation = localRoute
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

    public func routeChangeStream() -> AsyncStream<AudioRouteChangeEvent> { routeStream }

    /// Test seam — yield a synthetic interruption event into the stream.
    public func inject(_ event: AudioInterruptionEvent) {
        continuation.yield(event)
    }

    /// Test seam — yield a synthetic route event into the stream.
    public func inject(route event: AudioRouteChangeEvent) {
        routeContinuation.yield(event)
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

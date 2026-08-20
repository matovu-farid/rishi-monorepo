import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

/// Test seam over `AVAudioApplication`'s current permission +
/// async request. Production impl reads `AVAudioApplication.shared` and
/// `AVAudioApplication.requestRecordPermission`; tests inject a stub.
public protocol AudioApplicationProbing: Sendable {
    /// Current cached permission. iOS may return `.undetermined` until the
    /// user makes a choice; once they have, the result is sticky.
    func currentPermission() -> MicPermissionDecision

    /// Ask the OS for permission. Implementation MUST bridge the
    /// `(Bool) -> Void` completion into a single suspension point.
    func requestPermission() async -> Bool
}

/// Production conformer wrapping `AVAudioApplication` (iOS 17+ API).
///
/// VOICE-03: Mic permission gate calls
/// `AVAudioApplication.requestRecordPermission(completionHandler:)`. We
/// short-circuit on the cached `recordPermission` so a granted-or-denied
/// decision NEVER re-prompts the user.
public struct SystemMicPermissionGate: MicPermissionGate {
    private let probe: any AudioApplicationProbing

    public init(probe: any AudioApplicationProbing = SystemAudioApplicationProbe()) {
        self.probe = probe
    }

    public var currentDecision: MicPermissionDecision {
        probe.currentPermission()
    }

    public func request() async -> MicPermissionDecision {
        let cached = probe.currentPermission()
        switch cached {
        case .granted: return .granted
        case .denied:  return .denied
        case .undetermined:
            let granted = await probe.requestPermission()
            return granted ? .granted : .denied
        }
    }
}

/// Production `AudioApplicationProbing` backed by `AVAudioApplication`.
///
/// Stateless struct over OS singletons — the compiler proves Sendable
/// directly with no stored properties.
public struct SystemAudioApplicationProbe: AudioApplicationProbing {
    public init() {}

    public func currentPermission() -> MicPermissionDecision {
        #if canImport(AVFAudio) && (os(iOS) || targetEnvironment(macCatalyst))
        switch AVAudioApplication.shared.recordPermission {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .undetermined
        @unknown default:   return .undetermined
        }
        #else
        // macOS host / Linux CI: there's no `AVAudioApplication.shared`
        // mic permission concept. Treat as already-granted so dev-host tests
        // can construct the gate without hitting the OS.
        return .granted
        #endif
    }

    public func requestPermission() async -> Bool {
        #if canImport(AVFAudio) && (os(iOS) || targetEnvironment(macCatalyst))
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }
}

import Foundation

/// Outcome of a mic permission request.
public enum MicPermissionDecision: Sendable, Equatable {
    case granted
    case denied
    case undetermined  // user dismissed the system prompt without choosing
}

/// Seam over `AVAudioApplication.requestRecordPermission(completionHandler:)`.
/// Plan 10-04 ships the production impl `SystemMicPermissionGate`; tests
/// inject `FakeMicPermissionGate`.
public protocol MicPermissionGate: Sendable {
    /// Cached permission without prompting. This lets callers decide whether
    /// it is safe to construct an audio transport ahead of user intent.
    var currentDecision: MicPermissionDecision { get }

    /// Returns `.granted` if permission is (or becomes) authorized;
    /// `.denied` if the user denied it (or it was previously denied);
    /// `.undetermined` only on transient OS error.
    func request() async -> MicPermissionDecision
}

public extension MicPermissionGate {
    /// Test/fallback gates that only model the request operation do not expose
    /// a cached OS decision, so they conservatively disable early prewarm.
    var currentDecision: MicPermissionDecision { .undetermined }
}

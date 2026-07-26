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
    /// Returns `.granted` if permission is (or becomes) authorized;
    /// `.denied` if the user denied it (or it was previously denied);
    /// `.undetermined` only on transient OS error.
    func request() async -> MicPermissionDecision
}

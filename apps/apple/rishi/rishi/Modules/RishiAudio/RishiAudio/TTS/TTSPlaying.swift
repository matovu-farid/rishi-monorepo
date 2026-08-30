import Foundation

public protocol TTSMutationLease: Sendable {
    var isValid: Bool { get }
}

public struct TTSAlwaysValidLease: TTSMutationLease, Sendable {
    public init() {}
    public var isValid: Bool { true }
}

public struct TTSPlaybackRevokedError: Error, Sendable, Equatable {
    public init() {}
}

/// Testability seam at the top of the TTS pipeline (Phase 29, 29-RESEARCH §2).
///
/// `ReaderTTSBridge` consumes exactly this four-method subset of `TTSEngine`'s
/// public surface — start / pause / resume / stop. Depending on `any TTSPlaying`
/// instead of the concrete `TTSEngine` actor lets the bridge's
/// start/advance/stop/jump orchestration be driven deterministically in tests by
/// a `FakeTTSEngine`, with no live AVAudioEngine render cycle and no network.
///
/// `TTSEngine` conforms unchanged (its method signatures already match), so the
/// production object graph (AppDependencies) compiles byte-identically — a
/// `TTSEngine` still satisfies `any TTSPlaying`.
public protocol TTSPlaying: Sendable {
    func start(request: TTSStreamRequest) async
    func pause() async
    func resume() async
    func setVolume(_ volume: Float) async
    func stop() async
    /// Stops the request only when it is still the active request. Engines
    /// that multiplex requests override this to fence late cancellation.
    func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot) async
    /// Waits until the latest `start` completes successfully or fails.
    /// - Success only if playback actually started (`didStart`) then finished.
    /// - Throws on failure, stop, or finish-without-start.
    /// - Safe if finish happens before this call (pending result).
    func waitUntilFinished() async throws

    /// Lease-aware entry points used by remote/system control paths. The
    /// legacy methods remain available to existing local playback orchestration;
    /// all Watch-originated mutations use these guarded forms.
    func start(request: TTSStreamRequest, lease: any TTSMutationLease) async
    func pause(lease: any TTSMutationLease) async
    func resume(lease: any TTSMutationLease) async
    func stop(lease: any TTSMutationLease) async
    func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot, lease: any TTSMutationLease) async
    func waitUntilFinished(lease: any TTSMutationLease) async throws
}

public extension TTSPlaying {
    func setVolume(_ volume: Float) async {
        _ = volume
    }
    func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot) async {
        _ = tokens
        await stop()
    }

    func start(request: TTSStreamRequest, lease: any TTSMutationLease) async {
        guard lease.isValid else { return }
        await start(request: request)
    }

    func pause(lease: any TTSMutationLease) async {
        guard lease.isValid else { return }
        await pause()
    }

    func resume(lease: any TTSMutationLease) async {
        guard lease.isValid else { return }
        await resume()
    }

    func stop(lease: any TTSMutationLease) async {
        guard lease.isValid else { return }
        await stop()
    }

    func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot, lease: any TTSMutationLease) async {
        guard lease.isValid else { return }
        await stop(ifCurrent: tokens)
    }

    func waitUntilFinished(lease: any TTSMutationLease) async throws {
        guard lease.isValid else { throw TTSPlaybackRevokedError() }
        try await waitUntilFinished()
        guard lease.isValid else { throw TTSPlaybackRevokedError() }
    }
}

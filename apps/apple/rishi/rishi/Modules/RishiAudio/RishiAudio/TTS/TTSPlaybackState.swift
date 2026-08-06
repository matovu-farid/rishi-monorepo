import Foundation
import Observation

/// Playback status surfaced to SwiftUI. Drives the bottom-sheet controls
/// (plan 08-06) and the lock-screen NowPlayingController (plan 08-05).
public enum TTSStatus: String, Sendable, Equatable, CaseIterable, Codable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error
}

public struct TTSPlaybackTokenSnapshot: Sendable, Equatable, Hashable {
    public let sessionToken: UUID
    public let utteranceToken: UUID
    public let requestToken: UUID

    public init(sessionToken: UUID, utteranceToken: UUID, requestToken: UUID) {
        self.sessionToken = sessionToken
        self.utteranceToken = utteranceToken
        self.requestToken = requestToken
    }
}

/// @MainActor-isolated state object — SwiftUI views bind to it directly.
/// TTSEngine is an actor; it hops to @MainActor to update fields.
@Observable
@MainActor
public final class TTSPlaybackState {

    public private(set)  var  status : TTSStatus = .idle
    public var currentPassageId: String?
    public var elapsed: TimeInterval = 0
    public var error: String?

    public private(set) var activeTokenSnapshot: TTSPlaybackTokenSnapshot?
    public private(set) var typedFailure: WorkerAllowanceError?
    public private(set) var typedFailureTokens: TTSPlaybackTokenSnapshot?
    public private(set) var userFacingFailure: TTSUserFacingError?

    public typealias TypedFailureObserver = @MainActor (
        WorkerAllowanceError,
        TTSPlaybackTokenSnapshot
    ) -> Void
    private var typedFailureObservers: [UUID: TypedFailureObserver] = [:]

    public init() {}
    
    public func update(status: TTSStatus){
        guard typedFailure == nil || status == .error else { return }
        self.status = status
    }

    /// Stamps the request currently allowed to mutate shared playback state.
    /// Engines call this immediately before starting a tokened request; a
    /// late failure from any previous request is then rejected.
    public func activate(tokens: TTSPlaybackTokenSnapshot) {
        activeTokenSnapshot = tokens
    }

    @discardableResult
    public func observeTypedFailure(_ observer: @escaping TypedFailureObserver) -> UUID {
        let id = UUID()
        typedFailureObservers[id] = observer
        return id
    }

    public func removeTypedFailureObserver(_ id: UUID) {
        typedFailureObservers.removeValue(forKey: id)
    }

    public func recordTypedFailure(
        _ failure: WorkerAllowanceError,
        tokens: TTSPlaybackTokenSnapshot
    ) {
        guard typedFailure == nil,
              activeTokenSnapshot == tokens
        else { return }
        activeTokenSnapshot = tokens
        typedFailure = failure
        typedFailureTokens = tokens
        error = failure.message
        status = .error
        userFacingFailure = TTSUserFacingError.classify(failure)

        let observers = Array(typedFailureObservers.values)
        for observer in observers {
            observer(failure, tokens)
        }
    }

    public func recordUserFacingFailure(_ failure: TTSUserFacingError) {
        guard typedFailure == nil else { return }
        userFacingFailure = failure
        error = nil
        status = .error
    }

    public func clearFailure() {
        guard typedFailure == nil else { return }
        userFacingFailure = nil
        error = nil
        if status == .error { status = .stopped }
    }
    

    /// Ends the shared playback session and clears its sticky typed failure.
    public func endSession(preservingFailure: Bool = false) {
        status = .idle
        currentPassageId = nil
        elapsed = 0
        if !preservingFailure {
            error = nil
            typedFailure = nil
            typedFailureTokens = nil
            userFacingFailure = nil
        }
        activeTokenSnapshot = nil
    }

    /// Backwards-compatible reset for callers that only need to clear UI
    /// fields. A typed allowance failure is cleared only by `endSession()`.
    public func reset() {
        guard typedFailure == nil, userFacingFailure == nil else { return }
        update(status: .idle)
        currentPassageId = nil
        elapsed = 0
        error = nil
    }
}

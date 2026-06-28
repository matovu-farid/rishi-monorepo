import Foundation
import Observation

/// Playback status surfaced to SwiftUI. Drives the bottom-sheet controls
/// (plan 08-06) and the lock-screen NowPlayingController (plan 08-05).
public enum TTSStatus: String, Sendable, Equatable, CaseIterable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error
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

    public init() {}
    
    public func update(status: TTSStatus){
        self.status = status
    }
    

    /// Reset to .idle and clear transient fields. Used by TTSEngine.stop().
    public func reset() {
        status = .idle
        currentPassageId = nil
        elapsed = 0
        error = nil
    }
}

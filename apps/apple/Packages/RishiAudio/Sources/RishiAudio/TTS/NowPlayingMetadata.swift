import Foundation

/// Book-derived metadata for the lock-screen / Control Center surface.
/// Title comes from `Book.title`; author from `Book.author` (nullable in
/// RishiCore); `coverData` is the bytes the library already cached for the
/// cover image (passed in as Data so RishiAudio doesn't need to depend on
/// RishiLibrary's CoverImageStore).
public struct NowPlayingMetadata: Sendable, Equatable {
    public let title: String
    public let author: String?
    public let coverData: Data?

    public init(
        title: String,
        author: String? = nil,
        coverData: Data? = nil
    ) {
        self.title = title
        self.author = author
        self.coverData = coverData
    }
}

/// Which RemoteCommandCenter command the user triggered. Plain Swift enum
/// so tests can simulate handler invocations without touching MediaPlayer.
public enum RemoteCommand: Sendable, Equatable {
    case play
    case pause
    case togglePlayPause
    case previousTrack
    case nextTrack
    case stop
}

/// Handler bundle the controller registers with the command surface. All
/// closures are `@Sendable` and called from `@MainActor`.
public struct RemoteCommandHandlers: Sendable {
    public let onPlay: @Sendable @MainActor () -> Void
    public let onPause: @Sendable @MainActor () -> Void
    public let onTogglePlayPause: @Sendable @MainActor () -> Void
    public let onPreviousTrack: @Sendable @MainActor () -> Void
    public let onNextTrack: @Sendable @MainActor () -> Void
    public let onStop: @Sendable @MainActor () -> Void

    public init(
        onPlay: @Sendable @escaping @MainActor () -> Void,
        onPause: @Sendable @escaping @MainActor () -> Void,
        onTogglePlayPause: @Sendable @escaping @MainActor () -> Void,
        onPreviousTrack: @Sendable @escaping @MainActor () -> Void,
        onNextTrack: @Sendable @escaping @MainActor () -> Void,
        onStop: @Sendable @escaping @MainActor () -> Void
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onTogglePlayPause = onTogglePlayPause
        self.onPreviousTrack = onPreviousTrack
        self.onNextTrack = onNextTrack
        self.onStop = onStop
    }
}

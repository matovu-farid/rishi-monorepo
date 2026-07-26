import Foundation
import Observation

/// Source of truth for the in-flight chat turn.
///
/// `ChatPanelView` binds to this so the streaming "ghost" assistant bubble
/// updates token-by-token. The `@Observable` macro plus `@MainActor` isolation
/// guarantees:
///   - all reads on the SwiftUI render path see a consistent snapshot
///   - all mutations from `ChatPanelViewModel` land on the same actor as the
///     view, so we never need an `await` inside the render loop
///
/// Lifecycle (one turn):
///   ``beginStreaming()`` → N × ``appendToken(_:)`` → ``endStreaming()`` (on
///   completion or cancel) OR ``failStreaming(_:)`` (on error).
@MainActor
@Observable
public final class ChatStreamingState {

    /// `true` while a chat turn is in flight.
    public private(set) var isStreaming: Bool = false

    /// The accumulated assistant tokens for the current turn. `nil` when idle.
    /// The view renders this as a transient "ghost" bubble until the persisted
    /// assistant `Message` lands via `loadHistory`.
    public private(set) var streamingMessage: String? = nil

    /// The last error surfaced by the chat service, or `nil` if the previous
    /// turn succeeded. Cleared by ``beginStreaming()``.
    public private(set) var error: Error? = nil

    public init() {}

    /// Marks the start of a new turn. Clears any prior error and seeds an
    /// empty buffer so the view can render the ghost bubble immediately.
    public func beginStreaming() {
        isStreaming = true
        streamingMessage = ""
        error = nil
    }

    /// Appends a token to the streaming buffer. No-op when not streaming —
    /// late tokens arriving after cancel/end must not resurrect the ghost.
    public func appendToken(_ token: String) {
        guard isStreaming else { return }
        streamingMessage = (streamingMessage ?? "") + token
    }

    /// Marks the turn as complete. The persisted `Message` row (loaded by
    /// `ChatPanelViewModel.loadHistory`) replaces the ghost bubble.
    public func endStreaming() {
        isStreaming = false
        streamingMessage = nil
    }

    /// Records a failure for the current turn and clears streaming state.
    public func failStreaming(_ error: Error) {
        self.error = error
        isStreaming = false
        streamingMessage = nil
    }
}

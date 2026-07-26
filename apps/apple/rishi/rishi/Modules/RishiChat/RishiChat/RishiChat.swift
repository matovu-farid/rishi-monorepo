import Foundation

/// RishiChat — Feature-layer package owning the SSE chat panel + Conversations tab.
///
/// Phase 9 covers:
///   - SSEParser (line-by-line parsing of `data: { ... }\n\n` frames)
///   - ChatStreamEndpoint (POST /api/chat) — cloud RAG; no on-device embeddings
///   - ChatService actor — wires WorkerClient → ConversationStore + MessageStore
///     and exposes an `AsyncThrowingStream<ChatEvent, Error>` plus a cancel handle
///   - ChatPanelView — sheet presented from the reader, scoped to the open book
///   - ConversationsListView — root-tab list with search + delete + empty state
///
/// Depends DOWN on RishiCore (models + protocols), RishiUIKit (tokens),
/// RishiDB (GRDB store impls for tests), RishiAPI (WorkerClient + endpoint
/// protocols), RishiAuth (current user id, app-layer only), RishiLogging.
/// Has NO dependency on RishiReader, RishiSync, RishiLibrary, or RishiAudio
/// (cross-feature wiring is performed at the app layer via protocol seams).
enum RishiChat {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    static let version = "0.1.0-scaffold"
}

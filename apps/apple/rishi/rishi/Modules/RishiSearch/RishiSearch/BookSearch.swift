import Foundation

/// Public facade for per-book semantic search over the on-device HNSW
/// index. Plan 25-07 (`RealtimeClientAPI` extension) and Plan 25-09
/// (`BookContextResponder`) build against this protocol so they can be
/// wired up before the Plan 25-05 USearch production conformer lands.
///
/// Sendable because the production conformer is an actor and the test
/// fake (`StubBookSearch`) is `@unchecked Sendable` lock-guarded.
public protocol BookSearch: Sendable {
    /// Run a semantic search against the on-device index for `bookId`.
    /// Returns at most 3 hits ordered best-first. Implementations MUST
    /// throw `BookContextSearchError.indexNotReady` when the book has no
    /// usable index yet (cold-start sentinel) rather than returning an
    /// empty array — empty array means "ran the query, nothing matched".
    func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit]

    /// Snapshot of the per-book index state. Cold-start sentinel callers
    /// (e.g. the Responder before calling `search`) consult this to
    /// distinguish "index not built" from "no matches".
    func status(bookId: UUID) async -> BookSearchStatus
}

/// Errors surfaced by `BookSearch` conformers. Equatable so test
/// assertions can compare by case without value-shape gymnastics.
public enum BookContextSearchError: Error, Sendable, Equatable {
    /// No usable index exists for the requested book yet. Callers
    /// translate this into the Realtime tool result payload that tells
    /// the model the answer is unknown.
    case indexNotReady

    /// Query text could not be embedded (model load failure, tokenizer
    /// error, OOM during inference, etc.).
    case embeddingFailed(message: String)

    /// Catch-all for unexpected internal errors (index load failed, file
    /// corruption, USearch returned an error). Preserves a short message
    /// for logging without leaking the underlying type across the actor.
    case underlying(message: String)
}

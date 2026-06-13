import Foundation

/// Phase 21 Plan 21-03 — observable loading state surfaced by PDF + EPUB
/// reader view-models so screens can overlay a ProgressView during the
/// multi-second cold-open parse instead of showing a blank/frozen page.
///
/// Lifecycle:
/// - `.idle`: view-model constructed; `load()` has not been entered yet.
/// - `.loading`: `load()` has been entered and the parse is in flight.
/// - `.loaded`: `load()` returned successfully and the document /
///   publication is bound on the view-model.
/// - `.failed(reason:)`: `load()` returned without binding the document /
///   publication. `reason` is a human-readable string forwarded to the
///   failure overlay; it is NOT a localizable key — callers should pass
///   the underlying error's `localizedDescription` where possible.
///
/// Equatable so SwiftUI `.overlay { ... }` modifiers can pattern-match
/// cleanly; Sendable so the type can cross actor boundaries inside the
/// reader view-models (both VMs are `@unchecked Sendable`).
public enum ReaderLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(reason: String)
}

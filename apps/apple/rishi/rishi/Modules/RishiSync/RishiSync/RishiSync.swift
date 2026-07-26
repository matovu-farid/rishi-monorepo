import Foundation

/// RishiSync — Feature-layer package owning bidirectional R2 sync of books,
/// positions, highlights, and conversations across the user's Apple devices.
///
/// Architecture:
///   - SyncEngine (actor): owns the sync loop and serializes all sync work
///   - Outbound uploaders: BookUploader, PositionUploader, HighlightUploader
///   - Inbound: RemoteChangeFetcher + ChangeApplier (last-write-wins on metadata,
///     merge-by-id on highlights, content-addressed bytes for book files)
///   - Background: BackgroundTaskCoordinator (BGTaskScheduler) + SilentPushHandler (APNs)
///   - UI: SyncStatusView (last-sync time, pending count, manual "Sync now")
///
/// Depends DOWN on RishiCore (models + protocols), SwiftData-backed sync
/// metadata storage inside this package, RishiAPI (WorkerClient + SyncAPI
/// endpoints), RishiAuth (Session for user id), RishiUIKit (design tokens for
/// the status view), RishiLogging (os.Logger), and the sibling Feature package
/// RishiLibrary (BookFileStorage for resolving file URLs).
/// Has no dependency on RishiReader — the reader writes Positions; this
/// package reads them.
enum RishiSync {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    static let version = "0.1.0-scaffold"

    /// Wire-format tag for sync payloads. Schema changes require a bump
    /// AND a decoder fallback that still accepts the prior version.
    ///
    /// sync-v2 (Phase 37-08) adds the additive `bookmark` SyncEntityKind +
    /// bookmark payload codec. The bump is backward-compatible: prior sync-v1
    /// payloads (book/position/highlight/conversation/message) still decode
    /// unchanged (no field shape changed), and old clients gracefully skip the
    /// unknown `bookmark` kind via `ChangeApplier`'s unknown-kind branch.
    static let wireFormat = "sync-v2"
}

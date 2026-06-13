import Foundation
import RishiLogging

#if canImport(UIKit)
import UIKit

/// Routes the silent-push `application(_:didReceiveRemoteNotification:
/// fetchCompletionHandler:)` envelope into `SyncEngine.runOnce`.
///
/// Expected payload (per WORKER-TICKETS Ticket 3):
/// ```json
/// {
///   "aps": { "content-available": 1 },
///   "rishi": { "kind": "sync.changed", "changed_after": "<ISO8601>" }
/// }
/// ```
///
/// Mapping:
///   - missing / wrong `rishi.kind` → `.noData` (engine untouched)
///   - engine wave returns errors → `.failed`
///   - engine wave reports `fetched > 0 || applied > 0` → `.newData`
///   - otherwise → `.noData`
///
/// SYNC-06 iOS-side ships here; end-to-end verification is **deferred**
/// until the worker emits silent pushes on /api/sync/upload-url completion.
public enum SilentPushHandler {

    public static func handle(
        _ userInfo: [AnyHashable: Any],
        engine: SyncEngine,
        completion: @escaping @Sendable (UIBackgroundFetchResult) -> Void
    ) {
        guard
            let rishi = userInfo["rishi"] as? [String: Any],
            let kind = rishi["kind"] as? String,
            kind == "sync.changed"
        else {
            Log.event("sync.push.ignored", level: .info, data: [
                "reason": "missing-or-unknown-kind",
            ])
            completion(.noData)
            return
        }

        Log.event("sync.push.received", level: .info, data: [:])
        // KEEP: APNs silent-push delegate context is off-main (UIApplicationDelegate
        // invokes it on the main queue, but the work is engine.runOnce — an
        // actor method that hops to its own executor). Outer Task chains the
        // await; final completion(_:) call is explicitly re-entered on
        // MainActor below since UIBackgroundFetchResult must be reported on main.
        Task {
            let wave = await engine.runOnce()
            let outcome: UIBackgroundFetchResult
            if !wave.errors.isEmpty {
                outcome = .failed
            } else if wave.fetched > 0 || wave.applied > 0 {
                outcome = .newData
            } else {
                outcome = .noData
            }
            await MainActor.run { completion(outcome) }
        }
    }
}

#endif

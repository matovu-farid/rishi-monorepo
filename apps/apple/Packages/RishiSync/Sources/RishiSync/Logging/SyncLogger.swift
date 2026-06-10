import Foundation
import os
import RishiLogging

extension Log {
    /// Sync-specific logger. Subsystem `org.fidexa.rishi`, category `sync`.
    /// Mirrors the per-feature logger pattern established in Phase 02
    /// (`Log.persistence`) and consumed by Sentry breadcrumbs.
    public static let sync = Logger(subsystem: "org.fidexa.rishi", category: "sync")
}

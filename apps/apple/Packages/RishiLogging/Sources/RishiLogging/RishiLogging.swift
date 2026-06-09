// RishiLogging — structured os.Logger wrappers + Sentry breadcrumb forwarding.
// Initialize once at app launch via RishiLogging.start(dsn:environment:release:).
// All other code calls `Log.<subsystem>.info(...)` or `Log.event(...)`.

import Foundation
@_exported import os

public enum RishiLogging {
    /// Initialize the logging surface. Call this once at app launch — typically
    /// the very first line of `RishiApp.init` / `@main` setup.
    ///
    /// - Parameters:
    ///   - dsn: Sentry DSN, or `nil` to skip Sentry entirely (useful in tests).
    ///   - environment: "debug" / "testflight" / "production".
    ///   - release: Semantic version of the running app, e.g. "1.0.0 (42)".
    public static func start(dsn: String?, environment: String, release: String) {
        SentryBridge.start(dsn: dsn, environment: environment, release: release)
    }

    /// Marker for the public RishiLogging API version. Bump when the surface breaks.
    public static let apiVersion = "1.0.0"
}

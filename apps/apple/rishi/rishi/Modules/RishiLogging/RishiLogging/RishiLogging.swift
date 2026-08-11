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
    public static func start(
        dsn: String?,
        environment: String,
        release: String,
        enabled: Bool = true
    ) {
        SentryBridge.start(
            dsn: dsn,
            environment: environment,
            release: release,
            enabled: enabled
        )
    }

    /// Marker for the public RishiLogging API version. Bump when the surface breaks.
    static let apiVersion = "1.0.0"

    /// SET-02 — mute / unmute Sentry uploads at runtime in response to the
    /// user's telemetry opt-in toggle. The Phase 11 `AppTelemetrySink`
    /// forwards `TelemetryStore.setOptedIn(_:)` here.
    ///
    /// No-op when `RishiLogging.start(dsn:environment:release:)` has not been
    /// called with a real DSN — keeps tests + dev hosts well-defined.
    public static func setSentryEnabled(_ enabled: Bool) {
        SentryBridge.setEnabled(enabled)
    }
}

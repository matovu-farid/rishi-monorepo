import Foundation
import Sentry

/// Internal bridge between RishiLogging's `Log` surface and the Sentry SDK.
/// Designed to be safe to call before (or instead of) `SentrySDK.start(...)`.
enum SentryBridge {

    /// Tracks whether `start(...)` was called with a non-nil DSN.
    /// When false, breadcrumb/capture calls become no-ops so unit tests can
    /// exercise the Log surface without triggering Sentry network traffic.
    nonisolated(unsafe) private static var isLive: Bool = false

    static func start(dsn: String?, environment: String, release: String) {
        guard let dsn, !dsn.isEmpty else {
            isLive = false
            return
        }
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = release
            // Privacy-conservative defaults; the app target can override later.
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            // Sampling left at SDK default (1.0); tune in app target.
        }
        isLive = true
        wasStarted = true
    }

    /// Local mirror of whether `start(...)` was called with a real DSN. Used
    /// so `setEnabled(true)` does NOT silently enable a never-started SDK
    /// (would flip the breadcrumb gate true with no underlying client).
    nonisolated(unsafe) private static var wasStarted: Bool = false

    /// SET-02 — flip Sentry uploads on/off at runtime in response to the
    /// user's telemetry opt-in toggle.
    ///
    /// `isLive` is the breadcrumb / capture gate consulted by every Sentry
    /// forwarding call in this file, so toggling it is sufficient to mute
    /// uploads even without reaching into the Sentry SDK's options. We also
    /// close the SDK on opt-out so any in-flight envelopes are dropped.
    ///
    /// No-op when the SDK was never started — keeps tests + dev hosts well-
    /// defined (calling `setEnabled(true)` before `start(...)` does NOT
    /// enable a half-initialized state).
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            // Only honor opt-in if the SDK has actually been started.
            // Pre-start callers (tests, dev) get a no-op — same as today.
            isLive = wasStarted
        } else {
            isLive = false
            // Best-effort: drop any in-flight events on opt-out. SentrySDK
            // exposes `close()` across all supported versions; subsequent
            // breadcrumb / capture calls in this file are already gated by
            // `isLive` so they no-op.
            SentrySDK.close()
        }
    }

    static func addBreadcrumb(name: String, level: LogLevel, data: [String: String]?) {
        guard isLive else { return }
        let crumb = Breadcrumb()
        crumb.message = name
        crumb.level = mapLevel(level)
        if let data {
            crumb.data = data
        }
        SentrySDK.addBreadcrumb(crumb)
    }

    static func capture(error: Error) {
        guard isLive else { return }
        SentrySDK.capture(error: error)
    }

    private static func mapLevel(_ level: LogLevel) -> SentryLevel {
        switch level {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .warning
        case .error:   return .error
        case .fatal:   return .fatal
        }
    }
}

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

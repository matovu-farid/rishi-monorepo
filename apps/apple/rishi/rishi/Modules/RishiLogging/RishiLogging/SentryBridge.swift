import Foundation
// Uses Sentry 9.16.1's private file-manager SPI only to purge cached envelopes
// without invoking the public close API, which flushes pending data. Re-audit
// this call before upgrading the pinned Sentry SDK.
@_spi(Private) import Sentry

/// Internal bridge between RishiLogging's `Log` surface and the Sentry SDK.
/// Designed to be safe to call before (or instead of) `SentrySDK.start(...)`.
enum SentryBridge {

    static let breadcrumbMessage = "rishi.event"
    static let genericErrorMessage = "rishi.error"

    private static let state = LifecycleState()

    private final class LifecycleState: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var isLive = false
        var wasStarted = false
        var sdkStarted = false
        var configuration: Configuration?
        var urlSession: URLSession?
        var transitionGeneration = 0
        var cancellationInProgress = false
        var pendingEnable = false
    }

    private struct Configuration {
        let dsn: String
        let environment: String
        let release: String
    }

    static func start(
        dsn: String?,
        environment: String,
        release: String,
        enabled: Bool = true
    ) {
        guard let dsn = normalizedDSN(dsn) else { return }

        state.lock.lock()
        guard !state.wasStarted else {
            state.lock.unlock()
            return
        }

        let configuration = Configuration(dsn: dsn, environment: environment, release: release)
        state.configuration = configuration
        state.wasStarted = true
        state.isLive = enabled
        let shouldStartSDK = enabled
        state.sdkStarted = shouldStartSDK
        state.lock.unlock()

        if shouldStartSDK {
            startSDK(configuration)
        }
    }

    /// SET-02 — flip Sentry uploads on/off at runtime in response to the
    /// user's telemetry opt-in toggle.
    ///
    /// `isLive` is the breadcrumb / capture gate consulted by every Sentry
    /// forwarding call in this file and by the SDK's `beforeSend` filter. The
    /// SDK is not initialized for a launch-time opt-out; after a runtime
    /// opt-out it remains initialized, but in-flight requests are cancelled
    /// before cached envelopes are purged. The `beforeSend` gate also rejects
    /// newly captured events while consent is withdrawn. No shutdown flush is
    /// triggered.
    ///
    /// No-op when the SDK was never started — keeps tests + dev hosts well-
    /// defined (calling `setEnabled(true)` before `start(...)` does NOT
    /// enable a half-initialized state).
    static func setEnabled(_ enabled: Bool) {
        var configurationToStart: Configuration?
        var shouldPurgeCachedEnvelopes = false

        state.lock.lock()
        guard state.wasStarted else {
            state.lock.unlock()
            return
        }
        if enabled {
            guard !state.isLive, let configuration = state.configuration else {
                state.lock.unlock()
                return
            }
            if state.cancellationInProgress {
                state.pendingEnable = true
                state.lock.unlock()
                return
            }
            state.isLive = true
            if !state.sdkStarted {
                state.sdkStarted = true
                configurationToStart = configuration
            }
        } else {
            guard state.isLive else {
                if state.cancellationInProgress {
                    state.pendingEnable = false
                }
                state.lock.unlock()
                return
            }
            state.isLive = false
            shouldPurgeCachedEnvelopes = state.sdkStarted
            if shouldPurgeCachedEnvelopes {
                state.transitionGeneration += 1
                state.cancellationInProgress = true
            }
        }
        let transitionGeneration = state.transitionGeneration
        state.lock.unlock()

        if let configurationToStart {
            startSDK(configurationToStart)
        } else if shouldPurgeCachedEnvelopes {
            cancelInFlightRequests {
                state.lock.lock()
                guard state.transitionGeneration == transitionGeneration,
                      state.cancellationInProgress,
                      !state.isLive
                else {
                    state.lock.unlock()
                    return
                }
                let shouldEnable = state.pendingEnable
                state.pendingEnable = false
                purgeCachedEnvelopes()
                state.cancellationInProgress = false
                if shouldEnable {
                    state.isLive = true
                }
                state.lock.unlock()
            }
        }
    }

    static func addBreadcrumb(name: String, level: LogLevel, data: [String: String]?) {
        state.lock.lock()
        let isLive = state.isLive
        state.lock.unlock()
        guard isLive else { return }
        let crumb = Breadcrumb()
        crumb.message = breadcrumbMessage
        crumb.level = mapLevel(level)
        SentrySDK.addBreadcrumb(crumb)
    }

    static func capture(error: Error) {
        state.lock.lock()
        let isLive = state.isLive
        state.lock.unlock()
        guard isLive else { return }
        let sanitizedError = NSError(
            domain: "org.fidexa.rishi",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: genericErrorMessage]
        )
        SentrySDK.capture(error: sanitizedError)
    }

    static func purgeCachedEnvelopes() {
        SentryDependencyContainer.sharedInstance().fileManager?.deleteAllEnvelopes()
    }

    static func sanitizedBreadcrumbData(_ data: [String: String]?) -> [String: String]? {
        nil
    }

    private static func normalizedDSN(_ dsn: String?) -> String? {
        guard let dsn else { return nil }
        let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    private static func startSDK(_ configuration: Configuration) {
        let urlSession = URLSession(configuration: .ephemeral)
        state.lock.lock()
        state.urlSession = urlSession
        state.lock.unlock()

        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.environment = configuration.environment
            options.releaseName = configuration.release
            options.urlSession = urlSession
            // Keep the SDK initialized so a later opt-in can take effect without a
            // close/restart cycle. The bridge's gate controls delivery at the
            // beforeSend boundary, including the first-run opt-out state.
            options.enabled = true
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = false
            // The app's logs may contain book and conversation-derived values.
            // Keep Sentry to crash/error diagnostics until spans have an explicit
            // privacy contract of their own.
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableFileIOTracing = false
            options.enableDataSwizzling = false
            options.enableSwizzling = false
            options.enableCaptureFailedRequests = false
            options.enableAppHangTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableMetricKit = false
            options.enableMetrics = false
            options.tracesSampleRate = 0.0
            options.beforeSend = { event in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard state.isLive else { return nil }

                event.message = nil
                event.transaction = nil
                event.tags = nil
                event.extra = nil
                event.user = nil
                event.context = nil
                event.request = nil
                event.error = nil
                event.exceptions = event.exceptions?.map { exception in
                    exception.value = genericErrorMessage
                    exception.type = "RishiError"
                    exception.module = nil
                    exception.mechanism = nil
                    return exception
                }
                event.breadcrumbs = event.breadcrumbs?.map { breadcrumb in
                    breadcrumb.message = breadcrumbMessage
                    breadcrumb.data = nil
                    return breadcrumb
                }
                return event
            }
        }
    }

    private static func cancelInFlightRequests(completion: @escaping () -> Void) {
        state.lock.lock()
        let urlSession = state.urlSession
        state.lock.unlock()
        guard let urlSession else {
            completion()
            return
        }
        urlSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            completion()
        }
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

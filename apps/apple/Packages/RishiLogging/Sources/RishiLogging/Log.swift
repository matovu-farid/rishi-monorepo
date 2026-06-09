import Foundation
import os

/// Namespaced os.Logger surface. Subsystem is fixed to `org.fidexa.rishi`
/// (matches PRODUCT_BUNDLE_IDENTIFIER); each property is one category.
public enum Log {
    public static let subsystem = "org.fidexa.rishi"

    public static let app:    Logger = Logger(subsystem: subsystem, category: "app")
    public static let api:    Logger = Logger(subsystem: subsystem, category: "api")
    public static let reader: Logger = Logger(subsystem: subsystem, category: "reader")
    public static let audio:  Logger = Logger(subsystem: subsystem, category: "audio")
    public static let sync:   Logger = Logger(subsystem: subsystem, category: "sync")
    public static let auth:   Logger = Logger(subsystem: subsystem, category: "auth")

    // MARK: - Structured events

    /// Record a structured event. Always logs to `Log.app`; additionally adds a
    /// Sentry breadcrumb when the Sentry SDK has been initialized via
    /// `RishiLogging.start(dsn:...)`.
    public static func event(
        _ name: String,
        level: LogLevel = .info,
        data: [String: String]? = nil
    ) {
        let serialized = (data ?? [:])
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        Self.app.log(level: level.osLogType, "event: \(name, privacy: .public) \(serialized, privacy: .public)")
        SentryBridge.addBreadcrumb(name: name, level: level, data: data)
    }

    /// Log an error message. If `error` is non-nil and Sentry is initialized,
    /// the error is also captured to Sentry.
    public static func error(
        _ message: String,
        error: Error? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        Self.app.error("\(message, privacy: .public) [file=\(file, privacy: .public) line=\(line, privacy: .public)] error=\(String(describing: error), privacy: .public)")
        if let error {
            SentryBridge.capture(error: error)
        }
    }
}

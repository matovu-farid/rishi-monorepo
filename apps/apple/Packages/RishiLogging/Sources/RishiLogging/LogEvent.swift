import Foundation
import os

/// Severity level for `Log.event` and Sentry breadcrumbs.
/// Mirrors Sentry's `SentryLevel` raw values so the bridge is a pure mapping.
public enum LogLevel: String, Sendable, Hashable {
    case debug
    case info
    case warning
    case error
    case fatal

    /// Mapping to `OSLogType` for `Logger.log(level:)`.
    public var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default       // os doesn't have warning; default ~= notice
        case .error:   return .error
        case .fatal:   return .fault
        }
    }
}

import CryptoKit
import Foundation
import os

/// The only events that may enter the local shared-reading DEBUG dump. Keeping
/// this list closed prevents a future call site from accidentally serializing a
/// bearer token, invite, reader position, or peer-media payload.
public enum SharedReadingDiagnosticEvent: String, Sendable {
    case apiRequest = "sharing.api.request"
    case apiResponse = "sharing.api.response"
    case apiFailure = "sharing.api.failure"
    case authenticationRefresh = "sharing.authentication.refresh"
    case localBookValidation = "sharing.local_book.validation"
    case socket = "sharing.socket"
    case reconnect = "sharing.reconnect"
    case signalingEvent = "sharing.signaling.event"
    case recovery = "sharing.recovery"
    case registry = "sharing.registry"
    case sessionLifecycle = "sharing.session.lifecycle"
    case errorMapping = "sharing.error.mapping"
}

/// An allowlisted payload for `Log.sharedReading`. It intentionally has no
/// general dictionary initializer: session identifiers are hashed here and the
/// remaining fields are bounded protocol metadata rather than user content.
public struct SharedReadingDiagnosticContext: Sendable {
    public enum Outcome: String, Sendable {
        case started, completed, accepted, rejected, retrying, connected, disconnected, failed, skipped, ready
    }

    public enum Operation: String, Sendable {
        case create, email, redeem, bookReady = "book_ready", rejoin, active, status, start, end, leave, turn
        case controllerTransfer = "controller_transfer", participantRemove = "participant_remove", participantRestore = "participant_restore"
    }

    public let operation: Operation?
    public let outcome: Outcome?
    public let correlationID: String?
    public let operationID: UUID?
    private let sessionID: String?
    public let statusCode: Int?
    public let durationMilliseconds: Int?
    public let attempt: Int?
    public let roomEpoch: Int?
    public let rosterGeneration: Int?
    public let controllerGeneration: Int?
    public let connectionGeneration: Int?
    public let sequence: Int64?
    public let errorCode: String?

    public init(
        operation: Operation? = nil,
        outcome: Outcome? = nil,
        correlationID: String? = nil,
        operationID: UUID? = nil,
        sessionID: String? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        attempt: Int? = nil,
        roomEpoch: Int? = nil,
        rosterGeneration: Int? = nil,
        controllerGeneration: Int? = nil,
        connectionGeneration: Int? = nil,
        sequence: Int64? = nil,
        errorCode: String? = nil
    ) {
        self.operation = operation
        self.outcome = outcome
        self.correlationID = Self.safeOpaqueIdentifier(correlationID)
        self.operationID = operationID
        self.sessionID = sessionID
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.attempt = attempt
        self.roomEpoch = roomEpoch
        self.rosterGeneration = rosterGeneration
        self.controllerGeneration = controllerGeneration
        self.connectionGeneration = connectionGeneration
        self.sequence = sequence
        self.errorCode = Self.safeErrorCode(errorCode)
    }

    fileprivate var fields: [String: String] {
        var fields: [String: String] = [:]
        if let operation { fields["operation"] = operation.rawValue }
        if let outcome { fields["outcome"] = outcome.rawValue }
        if let correlationID { fields["correlation_id"] = correlationID }
        if let operationID { fields["operation_id"] = operationID.uuidString.lowercased() }
        if let sessionID {
            let digest = SHA256.hash(data: Data(sessionID.utf8))
            fields["session_debug_id"] = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        if let statusCode { fields["status_code"] = String(statusCode) }
        if let durationMilliseconds { fields["duration_ms"] = String(max(0, durationMilliseconds)) }
        if let attempt { fields["attempt"] = String(max(0, attempt)) }
        if let roomEpoch { fields["room_epoch"] = String(max(0, roomEpoch)) }
        if let rosterGeneration { fields["roster_generation"] = String(max(0, rosterGeneration)) }
        if let controllerGeneration { fields["controller_generation"] = String(max(0, controllerGeneration)) }
        if let connectionGeneration { fields["connection_generation"] = String(max(0, connectionGeneration)) }
        if let sequence { fields["sequence"] = String(max(0, sequence)) }
        if let errorCode { fields["error_code"] = errorCode }
        return fields
    }

    private static func safeOpaqueIdentifier(_ value: String?) -> String? {
        guard let value,
              value.count <= 128,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return value
    }

    private static func safeErrorCode(_ value: String?) -> String? {
        guard let value,
              value.count <= 64,
              value.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { return nil }
        return value
    }
}

/// Namespaced os.Logger surface. Subsystem is fixed to `org.fidexa.rishi`
/// (matches PRODUCT_BUNDLE_IDENTIFIER); each property is one category.
public enum Log {
    public static let subsystem = "org.fidexa.rishi"

    public static let app:         Logger = Logger(subsystem: subsystem, category: "app")
    public static let api:         Logger = Logger(subsystem: subsystem, category: "api")
    public static let reader:      Logger = Logger(subsystem: subsystem, category: "reader")
    public static let audio:       Logger = Logger(subsystem: subsystem, category: "audio")
    public static let sync:        Logger = Logger(subsystem: subsystem, category: "sync")
    public static let auth:        Logger = Logger(subsystem: subsystem, category: "auth")
    public static let persistence: Logger = Logger(subsystem: subsystem, category: "persistence")

    // MARK: - Test-only capture hook
    //
    // Assigned by test code to intercept every `Log.event(...)` call (in addition
    // to the normal os.Logger + SentryBridge path). Default `nil` — production
    // code never assigns it, so it's effectively zero-cost. The lock-guarded box
    // gives us a thread-safe seam without dragging Swift Concurrency isolation
    // into a static-stored property.
    public static let _testCapture = TestCaptureBox()

    // MARK: - Sink registry
    //
    // Lock-guarded box holding zero or more production sinks. Every `Log.event`
    // and `Log.error` call notifies every registered sink in addition to the
    // os.Logger / Sentry / test-capture paths. Default empty — production code
    // that needs a sink (e.g. `SimulatorDumpSink` in DEBUG simulator builds)
    // calls `Log.installSink(_:)` once at app launch.
    private static let _sinks = SinkRegistry()

    // @unchecked Sendable justified: holds mutable `var sinks` protected by
    // an internal NSLock; safety is externally provided rather than
    // compiler-proven, so the unchecked override is required.
    public final class SinkRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var sinks: [LogSink] = []

        public func install(_ sink: LogSink) {
            lock.lock(); defer { lock.unlock() }
            // Avoid duplicate registration of the same identity.
            if !sinks.contains(where: { $0 === sink }) {
                sinks.append(sink)
            }
        }

        public func remove(_ sink: LogSink) {
            lock.lock(); defer { lock.unlock() }
            sinks.removeAll { $0 === sink }
        }

        public func snapshot() -> [LogSink] {
            lock.lock(); defer { lock.unlock() }
            return sinks
        }
    }

    /// Install a production sink. Safe to call from any thread / actor.
    /// Sinks are notified on every `Log.event(...)` and `Log.error(...)` call
    /// for the lifetime of the process or until `Log.removeSink(_:)` is invoked.
    public static func installSink(_ sink: LogSink) {
        _sinks.install(sink)
    }

    /// Unregister a previously installed sink. Idempotent.
    public static func removeSink(_ sink: LogSink) {
        _sinks.remove(sink)
    }

    // @unchecked Sendable justified: holds a mutable `var _handler` closure
    // protected by an internal NSLock; safety is externally provided.
    public final class TestCaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: ((String, LogLevel, [String: String]?) -> Void)?

        public var handler: ((String, LogLevel, [String: String]?) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _handler }
            set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
        }

        public func reset() { handler = nil }

        public func notify(_ name: String, _ level: LogLevel, _ data: [String: String]?) {
            // Snapshot under the lock so notify() doesn't race against a setter
            // that nils the handler mid-call.
            let h: ((String, LogLevel, [String: String]?) -> Void)?
            lock.lock()
            h = _handler
            lock.unlock()
            h?(name, level, data)
        }
    }

    // MARK: - Structured events

    /// Record a structured event. Always logs to `Log.app`; additionally adds a
    /// Sentry breadcrumb when the Sentry SDK has been initialized via
    /// `RishiLogging.start(dsn:...)`. When a test installs `_testCapture.handler`,
    /// it is invoked on every call (used by RishiDB's BreadcrumbsTests).
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
        _testCapture.notify(name, level, data)
        for sink in _sinks.snapshot() {
            sink.record(name: name, level: level, data: data)
        }
    }

    /// Privacy-safe DEBUG diagnostic event for the shared-reading boundary.
    /// Release builds preserve the normal application log but never create the
    /// local dump sink; this helper has no upload or retry work of its own.
    public static func sharedReading(
        _ event: SharedReadingDiagnosticEvent,
        level: LogLevel = .info,
        context: SharedReadingDiagnosticContext = .init()
    ) {
        Self.event(event.rawValue, level: level, data: context.fields)
    }

    /// Log an error message. If `error` is non-nil and Sentry is initialized,
    /// the error is also captured to Sentry.
    public static func error(
        _ message: String,
        error: Error? = nil,
        diagnostic: TelemetryDiagnostic? = nil,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        Self.app.error("\(message, privacy: .public) [file=\(file, privacy: .public) line=\(line, privacy: .public)] error=\(String(describing: error), privacy: .public)")
        if let error {
            SentryBridge.capture(error: error, diagnostic: diagnostic)
        }
        // Fan out to registered production sinks so the DEBUG simulator dump
        // captures errors alongside structured events.
        var data: [String: String] = [
            "file": String(describing: file),
            "line": String(line),
        ]
        if let error {
            data["error"] = String(describing: error)
        }
        for sink in _sinks.snapshot() {
            sink.record(name: message, level: .error, data: data)
        }
    }
}

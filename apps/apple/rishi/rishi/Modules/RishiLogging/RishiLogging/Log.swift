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
        var fields = context.fields
        #if DEBUG
        fields.merge(SharedReadingRelayDelivery.shared.enqueue(
            event: event,
            level: level,
            fields: fields
        )) { _, relayValue in relayValue }
        #endif
        Self.event(event.rawValue, level: level, data: fields)
    }

    /// Best-effort delivery for the DEBUG relay. This deliberately has a
    /// bounded wait because app lifecycle transitions must never wait on local
    /// diagnostic infrastructure.
    public static func flushSharedReadingDiagnostics(timeout: TimeInterval = 1) async {
        #if DEBUG
        await SharedReadingRelayDelivery.shared.flush(timeout: timeout)
        #endif
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

#if DEBUG
private final class SharedReadingRelayDelivery: @unchecked Sendable {
    static let shared = SharedReadingRelayDelivery()

    private struct Configuration {
        let url: URL
        let key: String
        let actor: String
        let runID: String

        init?(environment: [String: String]) {
            guard let rawURL = environment["RISHI_SHARED_READING_RELAY_URL"],
                  let url = URL(string: rawURL),
                  url.scheme == "http",
                  url.host == "127.0.0.1",
                  let key = environment["RISHI_SHARED_READING_RELAY_KEY"],
                  key.count == 43,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  let actor = environment["RISHI_SHARED_READING_RELAY_ACTOR"],
                  ["owner-catalyst", "participant-iphone"].contains(actor),
                  let runID = environment["RISHI_SHARED_READING_RELAY_RUN_ID"],
                  Self.isOpaque(runID) else { return nil }
            self.url = url
            self.key = key
            self.actor = actor
            self.runID = runID
        }

        private static func isOpaque(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 128 && value.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
        }
    }

    private struct Record: Encodable {
        let eventTimestamp: String
        let event: String
        let level: String
        let fields: [String: String]
        let actor: String
        let runID: String
        let actorSequence: UInt64

        enum CodingKeys: String, CodingKey {
            case eventTimestamp = "event_timestamp"
            case event
            case level
            case fields
            case actor
            case runID = "run_id"
            case actorSequence = "actor_sequence"
        }
    }

    private let configuration = Configuration(environment: ProcessInfo.processInfo.environment)
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        JSONEncoder()
    }()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private var outbox: [Record] = []
    private var nextSequence: UInt64 = 0
    private var isDelivering = false
    private var retryCount = 0
    private let outboxLimit = 512

    private init() {}

    /// Returns safe run metadata so the local typed outbox can be imported once
    /// on the host without guessing which records belong to this relay run.
    func enqueue(
        event: SharedReadingDiagnosticEvent,
        level: LogLevel,
        fields: [String: String]
    ) -> [String: String] {
        guard let configuration else { return [:] }

        let record: Record
        lock.lock()
        nextSequence &+= 1
        let eventTimestamp = timestampFormatter.string(from: Date())
        var relayFields = fields
        relayFields["event_timestamp"] = eventTimestamp
        relayFields["relay_run_id"] = configuration.runID
        relayFields["actor"] = configuration.actor
        relayFields["actor_sequence"] = String(nextSequence)
        record = Record(
            eventTimestamp: eventTimestamp,
            event: event.rawValue,
            level: level.rawValue,
            fields: relayFields,
            actor: configuration.actor,
            runID: configuration.runID,
            actorSequence: nextSequence
        )
        if outbox.count == outboxLimit {
            outbox.removeFirst()
        }
        outbox.append(record)
        let shouldStart = !isDelivering
        if shouldStart { isDelivering = true }
        lock.unlock()

        if shouldStart { deliverNext() }
        return [
            "event_timestamp": eventTimestamp,
            "relay_run_id": configuration.runID,
            "actor": configuration.actor,
            "actor_sequence": String(record.actorSequence),
        ]
    }

    func flush(timeout: TimeInterval) async {
        guard configuration != nil else { return }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            lock.lock()
            let empty = outbox.isEmpty
            let shouldStart = !empty && !isDelivering
            if shouldStart { isDelivering = true }
            lock.unlock()
            if empty { return }
            if shouldStart { deliverNext() }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func deliverNext() {
        guard let configuration else { return }
        let record: Record?
        lock.lock()
        record = outbox.first
        if record == nil { isDelivering = false }
        lock.unlock()
        guard let record else { return }

        guard let body = try? encoder.encode(record) else {
            finishDelivery(success: false)
            return
        }
        var request = URLRequest(url: configuration.url.appendingPathComponent("events"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.key, forHTTPHeaderField: "X-Rishi-Shared-Reading-Key")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 202
            self?.finishDelivery(success: success)
        }.resume()
    }

    private func finishDelivery(success: Bool) {
        lock.lock()
        if success {
            if !outbox.isEmpty { outbox.removeFirst() }
            retryCount = 0
        } else {
            retryCount += 1
        }
        isDelivering = false
        let shouldContinue = success && !outbox.isEmpty
        let shouldRetry = !success && retryCount <= 3 && !outbox.isEmpty
        lock.unlock()

        if shouldContinue {
            lock.lock()
            isDelivering = true
            lock.unlock()
            deliverNext()
        } else if shouldRetry {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                guard !self.isDelivering, !self.outbox.isEmpty else {
                    self.lock.unlock()
                    return
                }
                self.isDelivering = true
                self.lock.unlock()
                self.deliverNext()
            }
        }
    }
}
#endif

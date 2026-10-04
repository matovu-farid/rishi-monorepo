import Foundation

/// A bounded set of stages for measuring whether an import can be opened
/// before its managed copy and optional cover work finish.
public struct BookImportMeasurement: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable, CaseIterable, Hashable {
        case requestReceived
        /// `BookFingerprintService.probeSelectedSource` combines provider
        /// coordination, digesting, and metadata extraction into one stage.
        case sourceProbeAndHashStarted
        case sourceProbeAndHashCompleted
        case reservationStarted
        case reservationCompleted
        case bookRegistered
        case baseLibraryPublished
        case readerSourceAcquired
        case readerAttachmentStarted
        case readerAttached
        case managedSourceReady
        case coverExtractionStarted
        case coverExtractionCompleted
        case coverHydrationCompleted
        case coverPublished
    }

    public enum ProviderKind: String, Codable, Sendable, CaseIterable {
        case fileImporter
        case securityScoped
        case fileProvider
        case directURL
        case appOwned
        case unknown
    }

    public enum CacheState: String, Codable, Sendable, CaseIterable {
        case hit
        case miss
        case bypassed
        case unknown
    }

    public let sequence: UInt64
    public let timestamp: Date
    public let stage: Stage
    public let importID: UUID
    public let attemptID: UUID?
    public let bookID: BookID?
    public let accountGeneration: UInt64?
    public let format: BookFormat?
    public let byteCount: Int64?
    public let providerKind: ProviderKind
    public let readableByteCount: Int64?
    public let cacheState: CacheState

    fileprivate var logFields: [String: String] {
        var fields = [
            "sequence": String(sequence),
            "stage": stage.rawValue,
            "import_id": importID.uuidString,
            "provider_kind": providerKind.rawValue,
            "cache_state": cacheState.rawValue,
        ]
        if let attemptID { fields["attempt_id"] = attemptID.uuidString }
        if let bookID { fields["book_id"] = bookID.uuidString }
        if let accountGeneration { fields["account_generation"] = String(accountGeneration) }
        if let format { fields["format"] = format.rawValue }
        if let byteCount { fields["byte_count"] = String(byteCount) }
        if let readableByteCount { fields["readable_byte_count"] = String(readableByteCount) }
        return fields
    }

    fileprivate init(
        sequence: UInt64,
        timestamp: Date,
        stage: Stage,
        context: BookImportInstrumentation.Context
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.stage = stage
        self.importID = context.importID
        self.attemptID = context.attemptID
        self.bookID = context.bookID
        self.accountGeneration = context.accountGeneration
        self.format = context.format
        self.byteCount = context.byteCount
        self.providerKind = context.providerKind
        self.readableByteCount = context.readableByteCount
        self.cacheState = context.cacheState
    }
}

/// Synchronous, privacy-bounded instrumentation for import ordering. The
/// context deliberately has no title, URL, path, filename, or document text
/// fields. A caller may send measurements to a metrics sink without exposing
/// book contents or source locations.
public final class BookImportInstrumentation: @unchecked Sendable {
    public struct Context: Sendable, Equatable {
        public let importID: UUID
        public let attemptID: UUID?
        public let bookID: BookID?
        public let accountGeneration: UInt64?
        public let format: BookFormat?
        public let byteCount: Int64?
        public let providerKind: BookImportMeasurement.ProviderKind
        public let readableByteCount: Int64?
        public let cacheState: BookImportMeasurement.CacheState

        public init(
            importID: UUID,
            attemptID: UUID? = nil,
            bookID: BookID? = nil,
            accountGeneration: UInt64? = nil,
            format: BookFormat? = nil,
            byteCount: Int64? = nil,
            providerKind: BookImportMeasurement.ProviderKind = .unknown,
            readableByteCount: Int64? = nil,
            cacheState: BookImportMeasurement.CacheState = .unknown
        ) {
            self.importID = importID
            self.attemptID = attemptID
            self.bookID = bookID
            self.accountGeneration = accountGeneration
            self.format = format
            self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
            self.providerKind = providerKind
            self.readableByteCount = readableByteCount.flatMap { $0 >= 0 ? $0 : nil }
            self.cacheState = cacheState
        }
    }

    public typealias Clock = @Sendable () -> Date
    public typealias Sink = @Sendable (BookImportMeasurement) -> Void

    private final class ImportScope: @unchecked Sendable {
        private let lock = NSLock()
        private let instrumentation: BookImportInstrumentation
        private var context: Context

        init(instrumentation: BookImportInstrumentation, context: Context) {
            self.instrumentation = instrumentation
            self.context = context
        }

        func record(
            _ stage: BookImportMeasurement.Stage,
            attemptID: UUID? = nil,
            bookID: BookID? = nil,
            format: BookFormat? = nil,
            byteCount: Int64? = nil,
            providerKind: BookImportMeasurement.ProviderKind? = nil,
            readableByteCount: Int64? = nil,
            cacheState: BookImportMeasurement.CacheState? = nil
        ) {
            lock.lock()
            defer { lock.unlock() }
            context = Context(
                importID: context.importID,
                attemptID: attemptID ?? context.attemptID,
                bookID: bookID ?? context.bookID,
                accountGeneration: context.accountGeneration,
                format: format ?? context.format,
                byteCount: byteCount ?? context.byteCount,
                providerKind: providerKind ?? context.providerKind,
                readableByteCount: readableByteCount ?? context.readableByteCount,
                cacheState: cacheState ?? context.cacheState
            )
            instrumentation.remember(context)
            instrumentation.record(stage, context: context)
        }
    }

    private struct ReaderOpenRequest {
        let importID: UUID
        let expiresAt: Date
    }

    @TaskLocal private static var activeImportScope: ImportScope?

    /// Shared production recorder. Tests and previews can inject their own
    /// recorder into the coordinator/storage/view model constructors.
    public static let shared = BookImportInstrumentation { measurement in
        Log.event("library.import.stage", level: .info, data: measurement.logFields)
    }

    private let lock = NSLock()
    private let now: Clock
    private let sink: Sink
    private var nextSequence: UInt64 = 0
    private var contextsByImportID: [UUID: Context] = [:]
    private var recordedStagesByImportID: [UUID: Set<BookImportMeasurement.Stage>] = [:]
    private var attemptToImportID: [UUID: UUID] = [:]
    private var latestImportIDByBookID: [BookID: UUID] = [:]
    private var pendingReaderOpenByBookID: [BookID: ReaderOpenRequest] = [:]
    private var activeReaderOpenByBookID: [BookID: ReaderOpenRequest] = [:]
    private var readerOpenRequestedImportIDs: Set<UUID> = []
    private var contextOrder: [UUID] = []

    private static let retainedImportContextLimit = 256
    private static let readerOpenRequestLifetime: TimeInterval = 30

    public init(now: @escaping Clock = { Date() }, sink: @escaping Sink) {
        self.now = now
        self.sink = sink
    }

    public func withImportContext<Value>(
        _ context: Context,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let scope = ImportScope(instrumentation: self, context: context)
        return try await Self.$activeImportScope.withValue(scope, operation: operation)
    }

    public static func recordCurrent(
        _ stage: BookImportMeasurement.Stage,
        attemptID: UUID? = nil,
        bookID: BookID? = nil,
        format: BookFormat? = nil,
        byteCount: Int64? = nil,
        providerKind: BookImportMeasurement.ProviderKind? = nil,
        readableByteCount: Int64? = nil,
        cacheState: BookImportMeasurement.CacheState? = nil
    ) {
        activeImportScope?.record(
            stage,
            attemptID: attemptID,
            bookID: bookID,
            format: format,
            byteCount: byteCount,
            providerKind: providerKind,
            readableByteCount: readableByteCount,
            cacheState: cacheState
        )
    }

    public static var hasActiveImportContext: Bool { activeImportScope != nil }

    /// Records a later detached stage using the attempt that was correlated
    /// when its registration reservation completed.
    public func record(_ stage: BookImportMeasurement.Stage, attemptID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let importID = attemptToImportID[attemptID],
              let context = contextsByImportID[importID] else { return }
        recordLocked(stage, context: context)
    }

    /// Records a reader/UI stage for the latest known import of a BookID.
    public func recordLatest(
        _ stage: BookImportMeasurement.Stage,
        bookID: BookID,
        providerKind: BookImportMeasurement.ProviderKind? = nil,
        readableByteCount: Int64? = nil,
        cacheState: BookImportMeasurement.CacheState? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let importID = latestImportIDByBookID[bookID],
              let prior = contextsByImportID[importID] else { return }
        let priorStages = recordedStagesByImportID[importID, default: []]
        // Reader events require an explicit one-shot open request from the
        // single-import auto-open path. Ordinary later reopens must not be
        // attributed to a historical import.
        guard stage != .readerSourceAcquired,
              stage != .readerAttachmentStarted,
              stage != .readerAttached else { return }
        let oneTimeStage = stage == .coverHydrationCompleted
        let requiresBasePublication = stage == .coverHydrationCompleted
        guard !requiresBasePublication || priorStages.contains(.baseLibraryPublished),
              !oneTimeStage || !priorStages.contains(stage) else { return }
        let context = Context(
            importID: prior.importID,
            attemptID: prior.attemptID,
            bookID: prior.bookID,
            accountGeneration: prior.accountGeneration,
            format: prior.format,
            byteCount: prior.byteCount,
            providerKind: providerKind ?? prior.providerKind,
            readableByteCount: readableByteCount ?? prior.readableByteCount,
            cacheState: cacheState ?? prior.cacheState
        )
        contextsByImportID[importID] = context
        recordLocked(stage, context: context)
    }

    /// Arms one reader trace for the explicit single-import auto-open callback.
    /// The marker is consumed at source acquisition, which can happen before
    /// the asynchronous base-library event is published.
    public func markReaderOpenRequested(bookID: BookID) {
        lock.lock()
        defer { lock.unlock() }
        guard let importID = latestImportIDByBookID[bookID],
              contextsByImportID[importID] != nil,
              readerOpenRequestedImportIDs.insert(importID).inserted else { return }
        pendingReaderOpenByBookID[bookID] = ReaderOpenRequest(
            importID: importID,
            expiresAt: now().addingTimeInterval(Self.readerOpenRequestLifetime)
        )
    }

    /// Records reader stages only for the one open explicitly requested by the
    /// import callback. The final attachment stage closes the eligibility.
    public func recordRequestedReaderOpen(
        _ stage: BookImportMeasurement.Stage,
        bookID: BookID,
        readableByteCount: Int64? = nil,
        cacheState: BookImportMeasurement.CacheState? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let importID: UUID
        if stage == .readerSourceAcquired {
            guard let request = pendingReaderOpenByBookID.removeValue(forKey: bookID),
                  now() <= request.expiresAt else { return }
            importID = request.importID
            activeReaderOpenByBookID[bookID] = request
        } else {
            guard let active = activeReaderOpenByBookID[bookID] else { return }
            guard now() <= active.expiresAt else {
                activeReaderOpenByBookID[bookID] = nil
                return
            }
            importID = active.importID
        }
        guard let prior = contextsByImportID[importID],
              !recordedStagesByImportID[importID, default: []].contains(stage) else { return }
        let context = Context(
            importID: prior.importID,
            attemptID: prior.attemptID,
            bookID: bookID,
            accountGeneration: prior.accountGeneration,
            format: prior.format,
            byteCount: prior.byteCount,
            providerKind: prior.providerKind,
            readableByteCount: readableByteCount ?? prior.readableByteCount,
            cacheState: cacheState ?? prior.cacheState
        )
        contextsByImportID[importID] = context
        recordLocked(stage, context: context)
        if stage == .readerAttached {
            activeReaderOpenByBookID[bookID] = nil
        }
    }

    /// Calls are linearized under a lock so `sequence` and sink delivery order
    /// match even when import stages arrive from different tasks.
    public func record(_ stage: BookImportMeasurement.Stage, context: Context) {
        lock.lock()
        defer { lock.unlock() }
        rememberLocked(context)
        recordLocked(stage, context: context)
    }

    private func remember(_ context: Context) {
        lock.lock()
        defer { lock.unlock() }
        rememberLocked(context)
    }

    private func rememberLocked(_ context: Context) {
        if contextsByImportID[context.importID] == nil {
            contextOrder.append(context.importID)
        }
        contextsByImportID[context.importID] = context
        if let attemptID = context.attemptID {
            attemptToImportID[attemptID] = context.importID
        }
        if let bookID = context.bookID {
            latestImportIDByBookID[bookID] = context.importID
        }
        while contextOrder.count > Self.retainedImportContextLimit {
            let expired = contextOrder.removeFirst()
            contextsByImportID[expired] = nil
            recordedStagesByImportID[expired] = nil
            attemptToImportID = attemptToImportID.filter { $0.value != expired }
            latestImportIDByBookID = latestImportIDByBookID.filter { $0.value != expired }
            pendingReaderOpenByBookID = pendingReaderOpenByBookID.filter { $0.value.importID != expired }
            activeReaderOpenByBookID = activeReaderOpenByBookID.filter { $0.value.importID != expired }
            readerOpenRequestedImportIDs.remove(expired)
        }
    }

    private func recordLocked(_ stage: BookImportMeasurement.Stage, context: Context) {
        recordedStagesByImportID[context.importID, default: []].insert(stage)
        let measurement = BookImportMeasurement(
            sequence: nextSequence,
            timestamp: now(),
            stage: stage,
            context: context
        )
        nextSequence &+= 1
        sink(measurement)
    }
}

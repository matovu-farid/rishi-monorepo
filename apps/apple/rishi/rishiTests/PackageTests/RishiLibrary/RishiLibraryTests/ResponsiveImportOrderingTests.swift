import Foundation
import Testing

@testable import rishi

@Suite("Responsive import instrumentation")
struct ResponsiveImportOrderingTests {
    @Test("records import stages in deterministic emission order")
    func recordsStagesInOrder() {
        let buffer = InstrumentationBuffer()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = BookImportInstrumentation(now: { timestamp }, sink: { buffer.append($0) })
        let context = BookImportInstrumentation.Context(
            importID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            bookID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountGeneration: 7,
            format: .pdf,
            byteCount: 4_096,
            providerKind: .fileProvider,
            readableByteCount: 4_096,
            cacheState: .miss
        )
        let stages: [BookImportMeasurement.Stage] = [
            .requestReceived,
            .sourceProbeAndHashStarted,
            .sourceProbeAndHashCompleted,
            .reservationStarted,
            .reservationCompleted,
            .bookRegistered,
            .baseLibraryPublished,
            .readerSourceAcquired,
            .readerAttached,
            .managedSourceReady,
            .coverExtractionCompleted,
        ]

        for stage in stages {
            recorder.record(stage, context: context)
        }

        let records = buffer.records
        #expect(records.map(\.stage) == stages)
        #expect(records.map(\.sequence) == Array(0..<UInt64(stages.count)))
        #expect(records.allSatisfy { $0.timestamp == timestamp })
        #expect(records.allSatisfy { $0.bookID == context.bookID && $0.attemptID == context.attemptID })
    }

    @Test("serialized measurements contain only allowlisted import metadata")
    func measurementsDoNotContainPrivateBookDetails() throws {
        let buffer = InstrumentationBuffer()
        let recorder = BookImportInstrumentation(now: { Date(timeIntervalSince1970: 1) }, sink: { buffer.append($0) })
        let privateAccountIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let context = BookImportInstrumentation.Context(
            importID: UUID(),
            attemptID: UUID(),
            bookID: UUID(),
            accountGeneration: 2,
            format: .epub,
            byteCount: 10,
            providerKind: .fileImporter,
            readableByteCount: 10,
            cacheState: .hit
        )

        recorder.record(.sourceProbeAndHashCompleted, context: context)

        let encoded = try JSONEncoder().encode(buffer.records)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(!serialized.contains("/private/imports/secret-book.epub"))
        #expect(!serialized.contains("Sensitive Book Title"))
        #expect(!serialized.contains("private chapter text"))
        #expect(!serialized.contains("ownerID"))
        #expect(!serialized.contains(privateAccountIdentifier.uuidString))
        #expect(serialized.contains("sourceProbeAndHashCompleted"))
        #expect(serialized.contains("fileImporter"))
    }

    @Test("recorder preserves stage ordering and detached attempt correlation")
    func detachedAttemptStagesFollowRecordedPublicationOrder() async {
        let buffer = InstrumentationBuffer()
        let recorder = BookImportInstrumentation(now: { Date(timeIntervalSince1970: 2) }, sink: { buffer.append($0) })
        let importID = UUID()
        let attemptID = UUID()
        let bookID = UUID()
        let gate = ImportStageGate()
        let context = BookImportInstrumentation.Context(
            importID: importID,
            accountGeneration: 9,
            format: .pdf,
            byteCount: 8_192,
            providerKind: .fileImporter,
            readableByteCount: 8_192,
            cacheState: .miss
        )

        await recorder.withImportContext(context) {
            BookImportInstrumentation.recordCurrent(.requestReceived)
            BookImportInstrumentation.recordCurrent(.sourceProbeAndHashStarted)
            BookImportInstrumentation.recordCurrent(.sourceProbeAndHashCompleted, attemptID: attemptID, bookID: bookID)
            BookImportInstrumentation.recordCurrent(.reservationStarted)
            BookImportInstrumentation.recordCurrent(.reservationCompleted, attemptID: attemptID)
            recorder.record(.bookRegistered, attemptID: attemptID)
            recorder.markReaderOpenRequested(bookID: bookID)
            recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)
            recorder.recordRequestedReaderOpen(.readerAttachmentStarted, bookID: bookID)
            recorder.recordRequestedReaderOpen(.readerAttached, bookID: bookID)
            // The explicit single-import callback can open the reader before
            // the VM publishes its asynchronous base-library event.
            recorder.record(.baseLibraryPublished, attemptID: attemptID)

            let materialization = Task.detached {
                await gate.blockUntilReleased()
                recorder.record(.managedSourceReady, attemptID: attemptID)
            }
            await gate.waitUntilBlocked()

            let beforeReady = buffer.records
            #expect(beforeReady.map(\.stage).contains(.baseLibraryPublished))
            #expect(beforeReady.map(\.stage).contains(.readerSourceAcquired))
            #expect(beforeReady.map(\.stage).contains(.readerAttached))
            #expect(!beforeReady.map(\.stage).contains(.managedSourceReady))

            await gate.release()
            await materialization.value
        }

        let stages = buffer.records.map(\.stage)
        #expect(stages.firstIndex(of: .baseLibraryPublished)! < stages.firstIndex(of: .managedSourceReady)!)
        #expect(stages.firstIndex(of: .readerSourceAcquired)! < stages.firstIndex(of: .managedSourceReady)!)
        #expect(stages.firstIndex(of: .readerAttached)! < stages.firstIndex(of: .managedSourceReady)!)
        #expect(stages.firstIndex(of: .readerAttached)! < stages.firstIndex(of: .baseLibraryPublished)!)
    }

    @Test("reader-open marker and cover hydration stages are one-time")
    func readerAndCoverStagesAreRecordedOncePerImport() {
        let buffer = InstrumentationBuffer()
        let recorder = BookImportInstrumentation(now: { Date(timeIntervalSince1970: 3) }, sink: { buffer.append($0) })
        let importID = UUID()
        let attemptID = UUID()
        let bookID = UUID()
        let context = BookImportInstrumentation.Context(
            importID: importID,
            attemptID: attemptID,
            bookID: bookID,
            accountGeneration: 11,
            format: .epub,
            byteCount: 17,
            providerKind: .fileProvider,
            readableByteCount: 17,
            cacheState: .miss
        )

        recorder.record(.bookRegistered, context: context)
        recorder.markReaderOpenRequested(bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttachmentStarted, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttached, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttached, bookID: bookID)
        // Historical imports must not capture an ordinary later reopen.
        recorder.recordLatest(.readerSourceAcquired, bookID: bookID, cacheState: .hit)
        recorder.recordLatest(.coverHydrationCompleted, bookID: bookID)
        recorder.record(.baseLibraryPublished, attemptID: attemptID)
        recorder.recordLatest(.coverHydrationCompleted, bookID: bookID, cacheState: .hit)
        recorder.recordLatest(.coverHydrationCompleted, bookID: bookID, cacheState: .hit)

        let records = buffer.records
        #expect(records.filter { $0.stage == .readerSourceAcquired }.count == 1)
        #expect(records.filter { $0.stage == .readerAttachmentStarted }.count == 1)
        #expect(records.filter { $0.stage == .readerAttached }.count == 1)
        #expect(records.filter { $0.stage == .coverHydrationCompleted }.count == 1)
        #expect(records.filter { $0.stage == .readerSourceAcquired }.first?.providerKind == .fileProvider)
    }

    @Test("an unconfirmed reader route cannot leave a pending open marker")
    func unconfirmedRouteDoesNotArmReaderTrace() {
        let buffer = InstrumentationBuffer()
        let recorder = BookImportInstrumentation(sink: { buffer.append($0) })
        let bookID = UUID()
        let context = BookImportInstrumentation.Context(
            importID: UUID(),
            attemptID: UUID(),
            bookID: bookID,
            accountGeneration: 3,
            format: .pdf,
            byteCount: 9,
            providerKind: .fileImporter
        )

        recorder.record(.bookRegistered, context: context)
        // LibraryRootView arms only when `onImported` confirms that it added a
        // new reader route/window. A fixture/no-op handler leaves this unset.
        recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttachmentStarted, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttached, bookID: bookID)

        #expect(buffer.records.map(\.stage) == [.bookRegistered])
    }

    @Test("an unconsumed reader-open marker expires")
    func readerOpenMarkerExpiresWithoutAttachment() {
        let buffer = InstrumentationBuffer()
        let clock = InstrumentationTestClock(Date(timeIntervalSince1970: 100))
        let recorder = BookImportInstrumentation(now: { clock.now }, sink: { buffer.append($0) })
        let bookID = UUID()
        let context = BookImportInstrumentation.Context(
            importID: UUID(),
            attemptID: UUID(),
            bookID: bookID,
            accountGeneration: 3,
            format: .epub,
            byteCount: 9,
            providerKind: .fileImporter
        )

        recorder.record(.bookRegistered, context: context)
        recorder.markReaderOpenRequested(bookID: bookID)
        clock.advance(by: 31)
        recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)

        #expect(buffer.records.map(\.stage) == [.bookRegistered])
    }

    @Test("reader attachment stages expire after source acquisition")
    func readerAttachmentMarkerExpiresAfterSourceAcquisition() {
        let buffer = InstrumentationBuffer()
        let clock = InstrumentationTestClock(Date(timeIntervalSince1970: 200))
        let recorder = BookImportInstrumentation(now: { clock.now }, sink: { buffer.append($0) })
        let bookID = UUID()
        let context = BookImportInstrumentation.Context(
            importID: UUID(),
            attemptID: UUID(),
            bookID: bookID,
            accountGeneration: 3,
            format: .pdf,
            byteCount: 9,
            providerKind: .fileImporter
        )

        recorder.record(.bookRegistered, context: context)
        recorder.markReaderOpenRequested(bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerSourceAcquired, bookID: bookID)
        clock.advance(by: 31)
        recorder.recordRequestedReaderOpen(.readerAttachmentStarted, bookID: bookID)
        recorder.recordRequestedReaderOpen(.readerAttached, bookID: bookID)

        #expect(buffer.records.map(\.stage) == [.bookRegistered, .readerSourceAcquired])
    }
}

private final class InstrumentationBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BookImportMeasurement] = []

    var records: [BookImportMeasurement] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ measurement: BookImportMeasurement) {
        lock.lock()
        stored.append(measurement)
        lock.unlock()
    }
}

private actor ImportStageGate {
    private var isBlocked = false
    private var isReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        isBlocked = true
        let entered = enteredWaiters
        enteredWaiters.removeAll()
        entered.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class InstrumentationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDate: Date

    init(_ date: Date) {
        storedDate = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return storedDate
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        storedDate.addTimeInterval(interval)
        lock.unlock()
    }
}

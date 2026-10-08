@testable import rishi
import Testing
import Foundation




/// SYNC-03 — PositionUploader: drain pending positions → POST /api/sync/push → markClean.
@Suite("PositionUploader", .serialized)
struct PositionUploaderTests {

    // MARK: - Stubs

    private actor StubMetadata: SyncMetadataStore {
        var cleanCalls: [(UUID, SyncEntityKind, Date, String?)] = []
        var forgetCalls: [(UUID, SyncEntityKind)] = []
        var conditionalAcknowledgementResult = true
        var operations: [UUID: UUID] = [:]
        var dirtyTime = Date(timeIntervalSince1970: 1_800_000_000)
        func operationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID? { operations[entityId] }
        func ensureOperationId(entityId: UUID, kind: SyncEntityKind) async throws -> UUID {
            if let value = operations[entityId] { return value }
            let value = UUID(); operations[entityId] = value; return value
        }
        func dirtyAt(entityId: UUID, kind: SyncEntityKind) async throws -> Date? { dirtyTime }
        func markCleanIfCurrent(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, expectedOperationId: UUID, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            guard operations[entityId] == expectedOperationId, expectedDirtyAt == dirtyTime else { return false }
            return try await markCleanIfUnchanged(entityId: entityId, kind: kind, expectedDirtyAt: expectedDirtyAt, lastSyncedAt: lastSyncedAt, remoteEtag: remoteEtag)
        }
        func moveRevision(_ id: UUID) { operations[id] = UUID(); dirtyTime = dirtyTime.addingTimeInterval(1) }


        func markDirty(entityId: UUID, kind: SyncEntityKind) async throws {}
        func markClean(entityId: UUID, kind: SyncEntityKind, lastSyncedAt: Date, remoteEtag: String?) async throws {
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
        }
        func allDirty() async throws -> [SyncPendingItem] { [] }
        func pending(kind: SyncEntityKind, limit: Int) async throws -> [SyncPendingItem] { [] }
        func pendingCount() async throws -> Int { 0 }
        func lastSyncedAt(forKind kind: SyncEntityKind) async throws -> Date? { nil }
        func globalLastSyncedAt() async throws -> Date? { nil }
        func forget(entityId: UUID, kind: SyncEntityKind) async throws {
            forgetCalls.append((entityId, kind))
        }
        func markCleanIfUnchanged(entityId: UUID, kind: SyncEntityKind, expectedDirtyAt: Date?, lastSyncedAt: Date, remoteEtag: String?) async throws -> Bool {
            guard conditionalAcknowledgementResult else { return false }
            cleanCalls.append((entityId, kind, lastSyncedAt, remoteEtag))
            return true
        }
        func recordRemoteSeen(entityId: UUID, kind: SyncEntityKind, updatedAt: Date) async throws {}

        func cleanedIds() -> [UUID] { cleanCalls.map(\.0) }
        func cleanCount() -> Int { cleanCalls.count }
        func cleanCursors() -> [Date] { cleanCalls.map(\.2) }
        func setConditionalAcknowledgementResult(_ value: Bool) { conditionalAcknowledgementResult = value }
    }

    private actor StubPositionStore: PositionStore {
        private var rows: [BookID: Position] = [:]
        private var readGate: ReadGate?
        func suspendReads(_ gate: ReadGate) { readGate = gate }

        func seed(_ rows: [Position]) {
            for r in rows { self.rows[r.bookId] = r }
        }
        func position(for bookId: BookID) async throws -> Position? {
            let row = rows[bookId]
            if let gate = readGate { readGate = nil; await gate.enter() }
            return row
        }
        func upsert(_ position: Position) async throws { rows[position.bookId] = position }
        func delete(_ id: PositionID) async throws {
            if let key = rows.first(where: { $0.value.id == id })?.key {
                rows[key] = nil
            }
        }
    }

    private actor StubBookStore: BookStore {
        func books(for userId: UserID) async throws -> [Book] { [] }
        func book(_ id: BookID) async throws -> Book? { nil }
        func upsert(_ book: Book) async throws {}
        func delete(_ id: BookID) async throws {}
    }

    // MARK: - Fixtures

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PositionUploaderMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeWorkerClient(session: URLSession) -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://worker.example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider("test-token"),
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()
        )
    }

    private let acceptedAtUnix: TimeInterval = 1_780_000_000

    // MARK: - Tests

    @Test("Happy path: one pending position → one POST /api/sync/push → markClean with response cursor")
    func happyPath() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let bookStore = StubBookStore()

        let bookId = UUID()
        let position = Position(
            id: UUID(),
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await positionStore.seed([position])

        // Reference-date offset = unix - 978307200
        let acceptedAtRef = acceptedAtUnix - 978_307_200
        PositionUploaderMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/sync/push")
            #expect(request.httpMethod == "POST")
            let body = """
            { "accepted_at": \(acceptedAtRef) }
            """
            return (200, Data(body.utf8), nil)
        }

        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: bookId, kind: .position),
        ])

        #expect(pushed == 1)
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [bookId])
        let cursors = await metadata.cleanCursors()
        #expect(cursors.first?.timeIntervalSince1970 == acceptedAtUnix)
    }

    @Test("Conditional acknowledgement failure leaves position pending and returns zero")
    func conditionalAcknowledgementFailureIsNotCounted() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        await metadata.setConditionalAcknowledgementResult(false)
        let positionStore = StubPositionStore()
        let bookStore = StubBookStore()
        let bookId = UUID()
        await positionStore.seed([Position(
            id: UUID(),
            bookId: bookId,
            locator: "pdf-v1:page:5",
            percentComplete: 0.25,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )])
        PositionUploaderMockURLProtocol.handler = { _ in
            (200, Data("{ \"accepted_at\": 946684800 }".utf8), nil)
        }

        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )
        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: bookId, kind: .position)
        ])

        #expect(pushed == 0)
        #expect(await metadata.cleanCount() == 0)
    }

    @Test("Empty input → 0 pushed, no HTTP call issued")
    func emptyInputDoesNothing() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore()
        let bookStore = StubBookStore()
        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        PositionUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }
        let pushed = try await uploader.pushPending(items: [])
        #expect(pushed == 0)
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
    }

    @Test("Missing local row → markClean drained, not sent in body, returns 0 live")
    func missingLocalRowDrained() async throws {
        PositionUploaderMockURLProtocol.reset()
        let session = makeSession()
        let workerClient = makeWorkerClient(session: session)
        let metadata = StubMetadata()
        let positionStore = StubPositionStore() // empty
        let bookStore = StubBookStore()

        let missingBookId = UUID()
        let uploader = PositionUploader(
            workerClient: workerClient,
            positionStore: positionStore,
            bookStore: bookStore,
            metadataStore: metadata
        )

        // No HTTP should fire — all items are stale.
        PositionUploaderMockURLProtocol.handler = { _ in (500, Data(), nil) }

        let pushed = try await uploader.pushPending(items: [
            SyncQueueItem(entityId: missingBookId, kind: .position),
        ])

        #expect(pushed == 0)
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        // Drained row should have been markClean'd so the queue stops surfacing it.
        let cleaned = await metadata.cleanedIds()
        #expect(cleaned == [missingBookId])
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let direct = request.httpBody { data = direct }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else { throw URLError(.badServerResponse) }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Operation outcomes acknowledge only applied/duplicate; missing and contradictory outcomes stay pending",
          arguments: ["applied", "duplicate", "rejected", "unknown", "missing", "contradictory", "legacy-rejected", "legacy"])
    func outcomes(_ status: String) async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata()
        let positions = StubPositionStore()
        let position = Position(bookId: UUID(), locator: "saved", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await positions.seed([position])
        let op = try await metadata.ensureOperationId(entityId: position.bookId, kind: .position)
        PositionUploaderMockURLProtocol.handler = { request in
            let parsed = try body(request)
            let changes = try #require(parsed["changes"] as? [[String: Any]])
            #expect(changes.first?["operation_id"] as? String == op.uuidString)
            #expect(changes.first?["updated_at"] as? Double == position.updatedAt.timeIntervalSinceReferenceDate)
            let outcomes: String
            if status == "missing" { outcomes = "[{\"operation_id\":\"other\",\"status\":\"applied\"}]" }
            else if status == "contradictory" {
                outcomes = "[{\"operation_id\":\"\(op)\",\"status\":\"applied\"},{\"operation_id\":\"\(op)\",\"status\":\"rejected\"}]"
            } else if status.hasPrefix("legacy") { outcomes = "[]" }
            else { outcomes = "[{\"operation_id\":\"\(op)\",\"status\":\"\(status)\"}]" }
            let accepted = status == "legacy-rejected" ? ",\"accepted\":false" : ""
            return (200, Data("{\"accepted_at\":123,\"outcomes\":\(outcomes)\(accepted)}".utf8), nil)
        }
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata)
        let result = try await uploader.pushPendingWithOutcomes(items: [.init(entityId: position.bookId, kind: .position)])
        #expect(result.acceptedCount == (["applied", "duplicate", "legacy"].contains(status) ? 1 : 0))
        #expect(result.rejected.count == (["rejected", "legacy-rejected"].contains(status) ? 1 : 0))
        if let rejected = result.rejected.first {
            #expect(rejected.position == position)
            #expect(rejected.operationID == op)
            #expect(rejected.dirtyAt == Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    @Test("Network retry preserves operation ID and saved timestamp")
    func stableRetry() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let position = Position(bookId: UUID(), locator: "saved", updatedAt: Date(timeIntervalSince1970: 10))
        await positions.seed([position])
        let operation = try await metadata.ensureOperationId(entityId: position.bookId, kind: .position)
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata)
        let items = [SyncQueueItem(entityId: position.bookId, kind: .position)]
        PositionUploaderMockURLProtocol.handler = { request in
            let changes = try #require(try body(request)["changes"] as? [[String: Any]])
            #expect(changes.first?["operation_id"] as? String == operation.uuidString)
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: (any Error).self) { try await uploader.pushPending(items: items) }
        #expect(await metadata.cleanCount() == 0)
        PositionUploaderMockURLProtocol.handler = { request in
            let changes = try #require(try body(request)["changes"] as? [[String: Any]])
            #expect(changes.first?["operation_id"] as? String == operation.uuidString)
            #expect(changes.first?["updated_at"] as? Double == position.updatedAt.timeIntervalSinceReferenceDate)
            return (200, Data("{\"accepted_at\":123}".utf8), nil)
        }
        #expect(try await uploader.pushPending(items: items) == 1)
    }

    @Test("A protected durable save cannot upload an older pending operation")
    func protectedSaveDoesNotUpload() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let position = Position(bookId: UUID(), locator: "durable-unpublished")
        await positions.seed([position])
        await metadata.protectPositionPublication(position.bookId)
        defer { Task { await metadata.releasePositionPublication(position.bookId) } }
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata)
        #expect(try await uploader.pushPending(items: [.init(entityId: position.bookId, kind: .position)]) == 0)
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
    }

    @Test("An older upload response cannot acknowledge concurrent movement")
    func oldResponseKeepsNewDirty() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let position = Position(bookId: UUID(), locator: "old")
        await positions.seed([position])
        let entered = DispatchSemaphore(value: 0); let resume = DispatchSemaphore(value: 0)
        PositionUploaderMockURLProtocol.handler = { _ in
            entered.signal(); resume.wait()
            return (200, Data("{\"accepted_at\":123}".utf8), nil)
        }
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata)
        let task = Task { try await uploader.pushPending(items: [.init(entityId: position.bookId, kind: .position)]) }
        await Task.detached { entered.wait() }.value
        await metadata.moveRevision(position.bookId)
        try await positions.upsert(Position(id: position.id, bookId: position.bookId, locator: "new", updatedAt: position.updatedAt.addingTimeInterval(1)))
        resume.signal()
        #expect(try await task.value == 0)
        #expect(await metadata.cleanCount() == 0)
    }

    @Test("Mixed batch counts applied and duplicate while returning rejected snapshot")
    func mixedBatch() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore()
        let rows = (0..<3).map { Position(bookId: UUID(), locator: "saved-\($0)") }
        await positions.seed(rows)
        var operations: [UUID] = []
        for row in rows { operations.append(try await metadata.ensureOperationId(entityId: row.bookId, kind: .position)) }
        let response = "{\"accepted_at\":123,\"accepted\":false,\"outcomes\":[{\"operation_id\":\"\(operations[0])\",\"status\":\"applied\"},{\"operation_id\":\"\(operations[1])\",\"status\":\"duplicate\"},{\"operation_id\":\"\(operations[2])\",\"status\":\"rejected\"}]}"
        PositionUploaderMockURLProtocol.handler = { _ in (200, Data(response.utf8), nil) }
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata)
        let result = try await uploader.pushPendingWithOutcomes(items: rows.map { .init(entityId: $0.bookId, kind: .position) })
        #expect(result.acceptedCount == 2)
        #expect(result.rejected.map(\.position) == [rows[2]])
        #expect(await metadata.cleanCount() == 2)
    }

    private actor Owner {
        var value: UserID
        init(_ value: UserID) { self.value = value }
        func set(_ value: UserID) { self.value = value }
    }
    private actor ReadGate {
        var entered = false
        var arrivals: [CheckedContinuation<Void, Never>] = []
        var waiter: CheckedContinuation<Void, Never>?
        func enter() async {
            entered = true; arrivals.forEach { $0.resume() }; arrivals.removeAll()
            await withCheckedContinuation { waiter = $0 }
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { arrivals.append($0) }
        }
        func resume() { waiter?.resume(); waiter = nil }
    }

    @Test("Account replacement during snapshot capture sends no stale request")
    func ownerSwitchDuringCapture() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore(); let owner = Owner(UUID())
        let position = Position(bookId: UUID(), locator: "old-account")
        await positions.seed([position])
        let gate = ReadGate(); await positions.suspendReads(gate)
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata, currentUserId: { await owner.value })
        let pending = Task { try await uploader.pushPending(items: [.init(entityId: position.bookId, kind: .position)]) }
        await gate.waitForEntry()
        await owner.set(UUID())
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(PositionUploaderMockURLProtocol.capturedSnapshot().isEmpty)
        #expect(await metadata.cleanCount() == 0)
    }

    @Test("Account replacement during network suspension cannot acknowledge old response")
    func ownerSwitchDuringNetwork() async throws {
        PositionUploaderMockURLProtocol.reset()
        let metadata = StubMetadata(); let positions = StubPositionStore(); let owner = Owner(UUID())
        let position = Position(bookId: UUID(), locator: "old-account")
        await positions.seed([position])
        let entered = DispatchSemaphore(value: 0); let resume = DispatchSemaphore(value: 0)
        PositionUploaderMockURLProtocol.handler = { _ in
            entered.signal(); resume.wait()
            return (200, Data("{\"accepted_at\":123}".utf8), nil)
        }
        let uploader = PositionUploader(workerClient: makeWorkerClient(session: makeSession()), positionStore: positions,
            bookStore: StubBookStore(), metadataStore: metadata, currentUserId: { await owner.value })
        let pending = Task { try await uploader.pushPending(items: [.init(entityId: position.bookId, kind: .position)]) }
        await Task.detached { entered.wait() }.value
        await owner.set(UUID()); resume.signal()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await metadata.cleanCount() == 0)
    }

}

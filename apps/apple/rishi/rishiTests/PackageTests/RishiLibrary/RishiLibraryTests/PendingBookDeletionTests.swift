@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Pending book deletion")
struct PendingBookDeletionTests {
    @Test("drains book users before tombstone and removes material only afterward")
    func drainsBeforeTombstoneAndRemoval() async throws {
        let owner = UUID()
        let bookID = UUID()
        let book = Book(
            id: bookID,
            userId: owner,
            title: "Pending PDF",
            formatType: .pdf,
            fileURL: "Books/\(bookID.uuidString)/pending.pdf"
        )
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("book bytes".utf8).write(to: file)
        let order = DeletionOrder()
        let gate = AsyncDeletionGate()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in
                await order.append("drain")
                try await gate.enterAndWait()
                return nil
            },
            onDelete: { _ in await order.append("tombstone") },
            deleteBook: { book in
                await order.append("material")
                try await storage.delete(book)
            }
        )

        await vm.refresh()
        let finished = DeletionCompletion()
        let deletion = Task { await vm.delete(book); await finished.finish() }
        do {
            try await gate.waitUntilEntered()
            #expect(try await store.book(book.id) == book)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(await order.events == ["drain"])
            await gate.release()
            try await finished.wait()
        } catch { await gate.release(); deletion.cancel(); throw error }

        #expect(await order.events == ["drain", "tombstone", "material"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.book(book.id) == nil)
        #expect(vm.books.isEmpty)
    }

    @Test("tombstone failure retains the book row and managed bytes")
    func tombstoneFailureRetainsBookAndMaterial() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Keep PDF", formatType: .pdf, fileURL: "Books/keep.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("book bytes".utf8).write(to: file)
        let order = DeletionOrder()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in await order.append("drain"); return nil },
            onDelete: { _ in
                await order.append("tombstone")
                throw TestFailure.tombstoneUnavailable
            },
            restoreAfterFailure: { _, _ in
                await order.append("restore")
                return .existingReady
            },
            deleteBook: { book in
                await order.append("material")
                try await storage.delete(book)
            }
        )

        await vm.refresh()
        await vm.delete(book)

        // A successful rollback clears the local deletion marker, so a fresh
        // registration event can publish after the tombstone write failed.
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 1, bookID: book.id, attemptID: UUID())
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 1, token: token, kind: .registered(book)))

        #expect(await order.events == ["drain", "tombstone", "restore"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.book(book.id) == book)
        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.deletionError != nil)
        vm.clearDeletionError()
        #expect(vm.deletionError == nil)
    }

    @Test("failed source restoration keeps the registration fence and exposes a retry error")
    func failedRestorationKeepsFence() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Fenced PDF", formatType: .pdf, fileURL: "Books/fenced.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let order = DeletionOrder()
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in await order.append("drain"); return nil },
            onDelete: { _ in throw TestFailure.tombstoneUnavailable },
            restoreAfterFailure: { _, _ in .refused },
            deleteBook: { _ in await order.append("material") }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 1, bookID: book.id, attemptID: UUID())

        await vm.refresh()
        await vm.delete(book)
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 1, token: token, kind: .registered(book)))

        #expect(vm.books.map(\.id) == [book.id])
        #expect(await order.events == ["drain"])
        #expect(vm.deletionError != nil)
        #expect(try await store.book(book.id) == book)
    }

    @Test("begin hides every projection and cache before scheduling completion; pending refresh and search stay hidden")
    func synchronousBeginHidesAllProjections() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Pending PDF", formatType: .pdf, fileURL: "pending.pdf")
        let other = Book(userId: owner, title: "Other PDF", formatType: .pdf, fileURL: "other.pdf")
        let position = Position(bookId: book.id, locator: "pending", percentComplete: 0.4)
        let otherPosition = Position(bookId: other.id, locator: "other", percentComplete: 0.6)
        let store = InMemoryBookStore(initial: [book, other])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let gate = AsyncDeletionGate()
        let events = DeletionOrder()
        let cover = root.appendingPathComponent("cover.png")
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            positionStore: InMemoryPositionStore(initial: [position, otherPosition]),
            coverResolver: BookCoverResolver(resolve: { _ in cover }),
            beforeDelete: { _ in await events.append("drain"); try await gate.enterAndWait(); return nil },
            onDelete: { _ in await events.append("tombstone") },
            deleteBook: { book in await events.append("material"); try await store.delete(book.id) }
        )
        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.readingNow.contains { $0.book.id == book.id })
        #expect(vm.coverURLs[book.id] == cover)
        vm.setGridBookVisible(book.id, visible: true)
        vm.setReadingNowBookVisible(book.id, visible: true)
        vm.setGridBookVisible(other.id, visible: true)
        vm.searchText = "Pending"
        let operation = try #require(vm.beginDeletion(book))

        // No background Task exists at this point: confirmation alone hides it.
        #expect(vm.books.map(\.id) == [other.id])
        #expect(!vm.readingNow.contains { $0.book.id == book.id })
        #expect(vm.filteredBooks.isEmpty)
        #expect(vm.positionsByBookId[book.id] == nil)
        #expect(vm.coverURLs[book.id] == nil)
        #expect(vm.prioritizedCoverBookIDs == [other.id])
        #expect(vm.position(for: other.id) == otherPosition)
        #expect(vm.coverURLs[other.id] == cover)
        #expect(await events.events.isEmpty)
        #expect(vm.beginDeletion(book) == nil)
        let finished = DeletionCompletion()
        let task = Task { await vm.completeDeletion(operation); await finished.finish() }
        do {
            try await gate.waitUntilEntered()
            await vm.refresh()
            vm.searchText = "PDF"
            let searchDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while vm.filteredBooks.map(\.id) != [other.id] {
                try Task.checkCancellation()
                guard ContinuousClock.now < searchDeadline else { throw TestFailure.timedOut }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(vm.books.map(\.id) == [other.id])
            #expect(vm.filteredBooks.map(\.id) == [other.id])
            #expect(!vm.readingNow.contains { $0.book.id == book.id })
            #expect(try await store.book(book.id) == book)
            #expect(await events.events == ["drain"])
            // Completing the same handle while its first completion is suspended is inert.
            await vm.completeDeletion(operation)
            #expect(await events.events == ["drain"])
            await gate.release()
            try await finished.wait()
        } catch { await gate.release(); task.cancel(); throw error }
        await vm.completeDeletion(operation)
        #expect(await events.events == ["drain", "tombstone", "material"])
        #expect(vm.books.map(\.id) == [other.id])
    }

    @Test("failed deletion restores cached presentation without a successful read and remains retryable", arguments: RollbackCase.allCases)
    fileprivate func failureRestoresCachedPresentation(_ rollback: RollbackCase) async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Retry PDF", formatType: .pdf, fileURL: "retry.pdf")
        let other = Book(userId: owner, title: "Unrelated", formatType: .pdf, fileURL: "other.pdf")
        let position = Position(bookId: book.id, locator: "saved", percentComplete: 0.3)
        let otherPosition = Position(bookId: other.id, locator: "other", percentComplete: 0.7)
        let store = DeletionBookStore([book, other])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let attempts = DeletionOrder()
        let cover = root.appendingPathComponent("cover.png")
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            positionStore: InMemoryPositionStore(initial: [position, otherPosition]),
            coverResolver: BookCoverResolver(resolve: { _ in cover }),
            beforeDelete: { _ in return nil },
            onDelete: { _ in
                await attempts.append("tombstone")
                if await attempts.events.count == 1 { throw TestFailure.tombstoneUnavailable }
            },
            restoreAfterFailure: { book, _ in rollback.result(for: book) },
            deleteBook: { book in try await store.delete(book.id) }
        )
        await vm.refresh()
        await vm.waitForHydration()
        vm.searchText = "Retry"
        let operation = try #require(vm.beginDeletion(book))
        await store.setReadFailure(true)
        await vm.refresh()
        await vm.completeDeletion(operation)
        #expect(Set(vm.books.map(\.id)) == [book.id, other.id])
        #expect(vm.filteredBooks.map(\.id) == [book.id])
        #expect(vm.readingNow.contains { $0.book.id == book.id })
        #expect(vm.position(for: book.id) == position)
        #expect(vm.coverURLs[book.id] == cover)
        #expect(vm.position(for: other.id) == otherPosition)
        #expect(vm.coverURLs[other.id] == cover)
        #expect(vm.deletionError?.contains(rollback.errorFragment) == true)
        #expect(try await store.book(book.id) == book)
        await vm.refresh()
        #expect(vm.books.contains { $0.id == book.id })
        let retry = try #require(vm.beginDeletion(book))
        #expect(!vm.books.contains { $0.id == book.id })
        await store.setReadFailure(false)
        await vm.completeDeletion(retry)
        #expect(vm.books.map(\.id) == [other.id])
        #expect(vm.deletionError == nil)
    }

    @Test("post-tombstone cleanup failure retains an absent canonical row as a visible retry through reads")
    func cleanupFailureRetainsAbsentRetry() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Cleanup retry", formatType: .pdf, fileURL: "cleanup.pdf")
        let store = DeletionBookStore([book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let events = DeletionOrder()
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            beforeDelete: { _ in await events.append("drain"); return nil },
            onDelete: { _ in await events.append("tombstone") },
            restoreAfterFailure: { _, _ in await events.append("rollback"); return .existingReady },
            deleteBook: { book in
                try await store.delete(book.id)
                await events.append("material")
                if await events.events.filter({ $0 == "material" }).count == 1 { throw TestFailure.cleanupUnavailable }
            }
        )
        await vm.refresh()
        let operation = try #require(vm.beginDeletion(book))
        await vm.completeDeletion(operation)
        #expect(try await store.book(book.id) == nil)
        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.deletionError?.contains("cleanup failed") == true)
        #expect(!(await events.events).contains("rollback"))
        await vm.refresh()
        #expect(vm.books.map(\.id) == [book.id])
        await store.setReadFailure(true)
        await vm.refresh()
        #expect(vm.books.map(\.id) == [book.id])
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 1, bookID: book.id, attemptID: UUID())
        var imported = book
        imported.title = "Fenced import"
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 1, token: token, kind: .registered(imported)))
        #expect(vm.books == [book])
        let retry = try #require(vm.beginDeletion(book))
        #expect(vm.books.isEmpty)
        await store.setReadFailure(false)
        await vm.completeDeletion(retry)
        #expect(vm.books.isEmpty)
        #expect(vm.deletionError == nil)
        #expect(await events.events == ["drain", "tombstone", "material", "drain", "tombstone", "material"])
    }

    @Test("deletion begun before the first snapshot survives owner adoption and failure before observation")
    func beginBeforeInitialSnapshot() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Early", formatType: .pdf, fileURL: "early.pdf")
        let store = DeletionBookStore([book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            beforeDelete: { _ in throw TestFailure.tombstoneUnavailable },
            onDelete: { _ in Issue.record("tombstone must not run after drain failure") },
            deleteBook: { _ in Issue.record("material must not run after drain failure") }
        )
        let operation = try #require(vm.beginDeletion(book))
        await store.setReadFailure(true)
        await vm.refresh()
        #expect(vm.books.isEmpty)
        await vm.completeDeletion(operation)
        #expect(vm.books == [book])
        #expect(vm.deletionError != nil)
        await store.setReadFailure(false)
        let retry = try #require(vm.beginDeletion(book))
        await vm.refresh()
        #expect(vm.books.isEmpty)
        await vm.completeDeletion(retry)
        #expect(vm.books == [book])
    }

    @Test("canonical absence controls rollback fallback; successful restoration supplies fresh proof", arguments: RollbackCase.allCases)
    fileprivate func canonicalAbsenceControlsFallback(_ rollback: RollbackCase) async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Externally absent", formatType: .pdf, fileURL: "absent.pdf")
        let store = DeletionBookStore([book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            beforeDelete: { _ in nil },
            onDelete: { _ in throw TestFailure.tombstoneUnavailable },
            restoreAfterFailure: { book, _ in rollback.result(for: book) },
            deleteBook: { _ in Issue.record("no material after failed tombstone") }
        )
        await vm.refresh()
        let operation = try #require(vm.beginDeletion(book))
        try await store.delete(book.id)
        await vm.refresh()
        await vm.completeDeletion(operation)
        #expect(vm.books.contains { $0.id == book.id } == (rollback == .restored))
        await vm.refresh()
        #expect(vm.books.isEmpty)
        #expect(vm.deletionError != nil)
    }

    @Test("accepted canonical replacement wins over the original rollback presentation and caches")
    func canonicalReplacementWins() async throws {
        let owner = UUID()
        let original = Book(userId: owner, title: "Original", formatType: .pdf, fileURL: "original.pdf")
        var replacement = original
        replacement.title = "Replacement"
        replacement.fileURL = "replacement.pdf"
        let position = Position(bookId: original.id, locator: "original", percentComplete: 0.5)
        let positions = InMemoryPositionStore(initial: [position])
        let store = DeletionBookStore([original])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let cover = root.appendingPathComponent("original.png")
        let vm = makeViewModel(
            book: original, store: store, storage: storage, positionStore: positions,
            coverResolver: BookCoverResolver(resolve: { book in book.fileURL == original.fileURL ? cover : nil }),
            beforeDelete: { _ in nil }, onDelete: { _ in throw TestFailure.tombstoneUnavailable },
            deleteBook: { _ in Issue.record("no material after failed tombstone") }
        )
        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.position(for: original.id) == position)
        #expect(vm.coverURLs[original.id] == cover)
        let operation = try #require(vm.beginDeletion(original))
        try await store.upsert(replacement)
        try await positions.delete(position.id)
        await vm.refresh()
        await vm.completeDeletion(operation)
        #expect(vm.books == [replacement])
        #expect(vm.position(for: original.id) == nil)
        #expect(vm.coverURLs[original.id] == nil)
        await vm.refresh()
        #expect(vm.books == [replacement])
    }

    @Test("concurrent different-book operations restore only their own failed row")
    func concurrentOperationsAreIndependent() async throws {
        let owner = UUID()
        let first = Book(userId: owner, title: "Fails", formatType: .pdf, fileURL: "first.pdf")
        let second = Book(userId: owner, title: "Succeeds", formatType: .pdf, fileURL: "second.pdf")
        let other = Book(userId: owner, title: "Untouched", formatType: .pdf, fileURL: "other.pdf")
        let store = InMemoryBookStore(initial: [first, second, other])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let firstGate = AsyncDeletionGate()
        let secondGate = AsyncDeletionGate()
        let vm = makeViewModel(
            book: first, store: store, storage: storage,
            beforeDelete: { book in
                try await (book.id == first.id ? firstGate : secondGate).enterAndWait()
                return nil
            },
            onDelete: { id in if id == first.id { throw TestFailure.tombstoneUnavailable } },
            deleteBook: { book in try await store.delete(book.id) }
        )
        await vm.refresh()
        let firstOperation = try #require(vm.beginDeletion(first))
        let secondOperation = try #require(vm.beginDeletion(second))
        #expect(vm.books == [other])
        let firstFinished = DeletionCompletion()
        let secondFinished = DeletionCompletion()
        let task1 = Task { await vm.completeDeletion(firstOperation); await firstFinished.finish() }
        let task2 = Task { await vm.completeDeletion(secondOperation); await secondFinished.finish() }
        do {
            try await firstGate.waitUntilEntered()
            try await secondGate.waitUntilEntered()
            await firstGate.release()
            try await firstFinished.wait()
            #expect(Set(vm.books.map(\.id)) == [first.id, other.id])
            #expect(vm.deletionError != nil)
            await vm.refresh()
            #expect(!vm.books.contains { $0.id == second.id })
            await secondGate.release()
            try await secondFinished.wait()
        } catch { await firstGate.release(); await secondGate.release(); task1.cancel(); task2.cancel(); throw error }
        #expect(Set(vm.books.map(\.id)) == [first.id, other.id])
        #expect(try await store.book(second.id) == nil)
    }

    @Test("generation replacement during an admitted stage starts no later stage and publishes no obsolete state", arguments: DeletionStage.allCases, [false, true])
    fileprivate func generationReplacementStopsLaterStages(_ stage: DeletionStage, _ changesUser: Bool) async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Outgoing", formatType: .pdf, fileURL: "outgoing.pdf")
        let other = Book(userId: owner, title: "Unrelated", formatType: .pdf, fileURL: "other.pdf")
        let store = DeletionBookStore([book, other])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let identity = LibraryAccountIdentity(userID: owner, generation: 1)
        var liveIdentity: LibraryAccountIdentity? = identity
        let generation = DeletionGeneration(1)
        let gate = AsyncDeletionGate()
        let events = DeletionOrder()
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            accountIdentity: identity, currentIdentity: { liveIdentity }, generation: { await generation.get() },
            beforeDelete: { _ in
                await events.append("drain")
                if stage == .drain { try await gate.enterAndWait() }
                return nil
            },
            onDelete: { _ in
                await events.append("tombstone")
                if stage == .tombstone { try await gate.enterAndWait() }
                if stage == .rollback { throw TestFailure.tombstoneUnavailable }
            },
            restoreAfterFailure: { _, _ in
                await events.append("rollback")
                if stage == .rollback { try? await gate.enterAndWait() }
                return .existingReady
            },
            deleteBook: { _ in await events.append("material") }
        )
        await vm.refresh()
        let operation = try #require(vm.beginDeletion(book))
        let finished = DeletionCompletion()
        let task = Task {
            await vm.completeDeletion(operation, closePresentedReader: { _ in
                await events.append("close")
                if stage == .close { try? await gate.enterAndWait() }
            })
            await finished.finish()
        }
        do {
            try await gate.waitUntilEntered()
            let reads = await store.readCount
            let visible = vm.books
            liveIdentity = LibraryAccountIdentity(userID: changesUser ? UUID() : owner, generation: 2)
            await generation.set(2)
            await gate.release()
            try await finished.wait()
            #expect(await events.events == stage.expectedEvents)
            #expect(await store.readCount == reads)
            #expect(vm.books == visible)
            #expect(vm.deletionError == nil)
            #expect(vm.beginDeletion(book) == nil)
            await vm.completeDeletion(operation)
            #expect(await events.events == stage.expectedEvents)
        } catch { await gate.release(); task.cancel(); throw error }
    }

    @Test("generation admission checks both the returned generation and identity after its await", arguments: [false, true])
    func generationLookupCannotAdmitObsoleteCompletion(_ changesIdentity: Bool) async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Await admission", formatType: .pdf, fileURL: "admission.pdf")
        let store = DeletionBookStore([book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let identity = LibraryAccountIdentity(userID: owner, generation: 1)
        var liveIdentity: LibraryAccountIdentity? = identity
        let gate = AsyncDeletionGate()
        let events = DeletionOrder()
        let vm = makeViewModel(
            book: book, store: store, storage: storage,
            accountIdentity: identity, currentIdentity: { liveIdentity },
            generation: {
                try? await gate.enterAndWait()
                return changesIdentity ? 1 : 2
            },
            beforeDelete: { _ in await events.append("drain"); return nil },
            onDelete: { _ in await events.append("tombstone") },
            deleteBook: { _ in await events.append("material") }
        )
        await vm.refresh()
        let operation = try #require(vm.beginDeletion(book))
        let finished = DeletionCompletion()
        let task = Task {
            await vm.completeDeletion(operation, closePresentedReader: { _ in await events.append("close") })
            await finished.finish()
        }
        do {
            try await gate.waitUntilEntered()
            if changesIdentity { liveIdentity = LibraryAccountIdentity(userID: owner, generation: 2) }
            await gate.release()
            try await finished.wait()
            #expect(await events.events.isEmpty)
            #expect(await store.readCount == 1)
            #expect(vm.books.isEmpty)
            #expect(vm.deletionError == nil)
            #expect(try await store.book(book.id) == book)
        } catch { await gate.release(); task.cancel(); throw error }
    }

    private func makeViewModel(
        book: Book,
        store: any BookStore,
        storage: BookFileStorage,
        positionStore: any PositionStore = InMemoryPositionStore(),
        coverResolver: BookCoverResolver = BookCoverResolver(resolve: { _ in nil }),
        accountIdentity: LibraryAccountIdentity? = nil,
        currentIdentity: @escaping @MainActor () -> LibraryAccountIdentity? = { nil },
        generation: @escaping @Sendable () async -> UInt64? = { 1 },
        beforeDelete: @escaping @Sendable (Book) async throws -> BookDeletionRetirementWitness?,
        onDelete: @escaping @Sendable (BookID) async throws -> Void,
        restoreAfterFailure: @escaping @Sendable (Book, BookDeletionRetirementWitness?) async -> BookDeletionRollbackResult = { _, _ in .existingReady },
        deleteBook: @escaping @Sendable (Book) async throws -> Void
    ) -> LibraryViewModel {
        LibraryViewModel(
            bookStore: store,
            currentUserId: { book.userId },
            boundAccountIdentity: accountIdentity,
            currentAccountIdentity: currentIdentity,
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { book.userId }),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: coverResolver,
            deleteBook: deleteBook,
            beforeBookDeleted: beforeDelete,
            restoreBookAfterFailedRetirement: restoreAfterFailure,
            onBookDeleted: onDelete,
            currentAccountGeneration: generation
        )
    }

    private func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("PendingBookDeletion-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor DeletionOrder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor AsyncDeletionGate {
    private var didEnter = false
    private var released = false

    func enterAndWait() async throws {
        didEnter = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !released {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !didEnter {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() { released = true }
}

private actor DeletionCompletion {
    private var finished = false
    func finish() { finished = true }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !finished {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor DeletionBookStore: BookStore {
    private let store: InMemoryBookStore
    private var failReads = false
    private(set) var readCount = 0
    init(_ books: [Book]) { store = InMemoryBookStore(initial: books) }
    func setReadFailure(_ fail: Bool) { failReads = fail }
    func books(for owner: UserID) async throws -> [Book] {
        readCount += 1
        if failReads { throw TestFailure.readUnavailable }
        return try await store.books(for: owner)
    }
    func book(_ id: BookID) async throws -> Book? { try await store.book(id) }
    func upsert(_ book: Book) async throws { try await store.upsert(book) }
    func delete(_ id: BookID) async throws { try await store.delete(id) }
    func deleteIfUnchanged(_ id: BookID, matching book: Book?) async throws -> Bool {
        try await store.deleteIfUnchanged(id, matching: book)
    }
}

private actor DeletionGeneration {
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func get() -> UInt64 { value }
    func set(_ value: UInt64) { self.value = value }
}

private enum RollbackCase: CaseIterable, Sendable, Equatable {
    case restored, refused, conflict
    func result(for book: Book) -> BookDeletionRollbackResult {
        switch self {
        case .restored: .existingReady
        case .refused: .refused
        case .conflict: .conflict(BookMaterializationToken(ownerID: book.userId, accountGeneration: 1, bookID: book.id, attemptID: UUID()))
        }
    }
    var errorFragment: String {
        switch self {
        case .restored: "try again"
        case .refused: "safely restore"
        case .conflict: "conflict"
        }
    }
}

private enum DeletionStage: String, CaseIterable, Sendable, Equatable {
    case close, drain, tombstone, rollback
    var expectedEvents: [String] {
        switch self {
        case .close: ["close"]
        case .drain: ["close", "drain"]
        case .tombstone: ["close", "drain", "tombstone"]
        case .rollback: ["close", "drain", "tombstone", "rollback"]
        }
    }
}

private enum TestFailure: Error {
    case tombstoneUnavailable, readUnavailable, cleanupUnavailable, timedOut
}

@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Library import missed completion")
struct LibraryImportMissedCompletionTests {
    private actor ResolverProbe {
        private var calls = 0
        private var callWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        func resolve(_ book: Book, coverURL: URL) -> URL? {
            calls += 1
            let waiters = callWaiters.values
            callWaiters.removeAll()
            waiters.forEach { $0.resume(returning: true) }
            return book.coverPath == nil ? nil : coverURL
        }
        func count() -> Int { calls }
        func waitForCall() async -> Bool {
            if calls > 0 { return true }
            let id = UUID()
            return await withCheckedContinuation { continuation in
                callWaiters[id] = continuation
                Task {
                    // Timeout bounds a broken observer without using a delay
                    // to coordinate the successful recovery path.
                    try? await Task.sleep(for: .seconds(5))
                    self.callWaiters.removeValue(forKey: id)?.resume(returning: false)
                }
            }
        }
    }

    @Test("refresh publishes persisted artwork when all completion events were missed")
    func refreshRecoversMissedManagedAndCoverCompletion() async throws {
        try await assertRefreshRecoversPersistedArtwork(deliverManagedReady: false)
    }

    @Test("refresh publishes persisted artwork when only cover completion was missed")
    func refreshRecoversMissedCoverCompletion() async throws {
        try await assertRefreshRecoversPersistedArtwork(deliverManagedReady: true)
    }

    @Test("reattaching observer recovers artwork persisted without completion hints")
    func observerReattachmentRecoversPersistedArtwork() async throws {
        try await assertRefreshRecoversPersistedArtwork(deliverManagedReady: false, reattachObserver: true)
    }

    @Test("pending artwork recovery still honors resolver authorization")
    func recoveredArtworkStillRequiresResolverAuthorization() async throws {
        try await assertRefreshRecoversPersistedArtwork(deliverManagedReady: false, denyArtwork: true)
    }

    private func assertRefreshRecoversPersistedArtwork(
        deliverManagedReady: Bool,
        reattachObserver: Bool = false,
        denyArtwork: Bool = false
    ) async throws {
        let owner = UUID()
        let generation: UInt64 = 81
        let id = UUID()
        var canonical = Book(id: id, userId: owner, title: "Imported artwork", formatType: .epub,
                             fileURL: "Books/\(id.uuidString)/book.epub")
        let store = InMemoryBookStore()
        let root = URL.temporaryDirectory.appendingPathComponent("MissedCover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let coverURL = root.appendingPathComponent("Books/\(id.uuidString)/cover.png")
        let resolverProbe = ResolverProbe()
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { owner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { book in
                await resolverProbe.resolve(book, coverURL: coverURL)
            }, isArtworkReadAllowed: { _ in !denyArtwork }),
            deleteBook: { _ in },
            bookImportEvents: BookImportEvents(),
            currentAccountGeneration: { generation }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: generation,
                                            bookID: id, attemptID: UUID())
        // Establish the library's published owner before registration, as
        // production initial loading does. Otherwise the first refresh clears
        // all pending state as an owner transition and masks the regression.
        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.books.isEmpty)
        #expect(await resolverProbe.count() == 0)
        // Import registration persists the row before publishing its hint.
        try await store.upsert(canonical)
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: generation,
                                                token: token, kind: .registered(canonical)))
        await vm.waitForHydration()
        #expect(vm.books.map(\.id) == [id])
        #expect(vm.coverURLs[id] == nil)
        #expect(await resolverProbe.count() == 0,
                "Pending registration must suppress extraction before persisted artwork exists")

        if deliverManagedReady {
            await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: generation,
                                                    token: token, kind: .managedReady(id)))
            await vm.waitForImportEventRefresh()
            await vm.waitForHydration()
        }
        // The importer commits this canonical update while the library's
        // observer is absent. No cover completion hint is delivered to the VM.
        canonical.coverPath = "Books/\(id.uuidString)/cover.png"
        try await store.upsert(canonical)
        if reattachObserver {
            let observer = Task { await vm.observeImportEvents() }
            defer { observer.cancel() }
            let resolved = await resolverProbe.waitForCall()
            observer.cancel()
            await observer.value
            #expect(resolved, "Observer reattachment must refresh persisted artwork within the timeout")
        } else {
            await vm.refresh()
        }
        await vm.waitForHydration()

        #expect(vm.books.first?.coverPath == canonical.coverPath)
        if denyArtwork {
            #expect(vm.coverURLs[id] == nil)
            #expect(await resolverProbe.count() == 0,
                    "Artwork recovery must not bypass the resolver's read authority")
        } else {
            #expect(vm.coverURLs[id] == coverURL,
                    "A snapshot refresh must recover canonical artwork without restarting the app")
        }
    }
}

import Foundation

extension Notification.Name {
    static let rishiSearchableDataDidChange = Notification.Name("Rishi.searchableDataDidChange")
}

struct SystemIntegrationRuntime: @unchecked Sendable {
    let spotlight: RishiSpotlightCoordinator
}

struct RishiSpotlightTransitionResult: Sendable {
    let identityApplied: Bool
    let cleanupComplete: Bool
}

private actor RishiSpotlightOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        guard let waiter = waiters.first else {
            isLocked = false
            return
        }
        waiters.removeFirst()
        waiter.resume()
    }
}

actor RishiSpotlightCoordinator {
    private let bookStore: any BookStore
    private let highlightStore: any HighlightStore
    private let conversationStore: any ConversationStore
    private let currentUserID: @Sendable () async -> UserID?
    private let indexingClient: any RishiSearchIndexingClient

    private var requestedGeneration: UInt64 = 0
    private var isReindexing = false
    private var indexGeneration: UInt64 = 0
    private var transitionOwnerGeneration: UInt64?
    private var cleanupPending = false
    private var suppressReindexAfterCleanup = false
    private var cleanupRequiredFor: UserID?
    private var cleanupRequiredGeneration: UInt64?
    private var retryTask: Task<Void, Never>?
    private var cleanupRetryInProgress = false
    private var transitionInProgress = false
    private let operationGate = RishiSpotlightOperationGate()

    init(
        bookStore: any BookStore,
        highlightStore: any HighlightStore,
        conversationStore: any ConversationStore,
        currentUserID: @escaping @Sendable () async -> UserID?,
        indexingClient: any RishiSearchIndexingClient
    ) {
        self.bookStore = bookStore
        self.highlightStore = highlightStore
        self.conversationStore = conversationStore
        self.currentUserID = currentUserID
        self.indexingClient = indexingClient
    }

    func requestReindex() async {
        requestedGeneration &+= 1
        guard !isReindexing, !transitionInProgress else { return }
        isReindexing = true
        defer { isReindexing = false }

        while true {
            let generation = requestedGeneration
            await reindexCurrentUser()
            guard generation != requestedGeneration else { return }
        }
    }

    func reindexCurrentUser() async {
        guard !transitionInProgress else { return }

        if cleanupPending {
            let suppressReindex = suppressReindexAfterCleanup
            guard retryTask == nil, !cleanupRetryInProgress else { return }
            guard await retryCleanupIfNeeded() else {
                if !cleanupRetryInProgress { scheduleCleanupRetry(after: .seconds(60)) }
                return
            }
            if suppressReindex { return }
        }

        guard let userID = await currentUserID() else {
            let generation = indexGeneration
            guard await clearIndex() else {
                cleanupPending = true
                cleanupRequiredFor = nil
                cleanupRequiredGeneration = generation
                scheduleCleanupRetry()
                return
            }
            guard generation == indexGeneration, await currentUserID() == nil else { return }
            return
        }

        let generation = indexGeneration
        do {
            let books = try await bookStore.books(for: userID).filter { $0.userId == userID }
            let conversations = try await conversationStore.conversations(for: userID)
                .filter { $0.userId == userID }
            var descriptors = books.map(RishiSpotlightDescriptor.book)
            for book in books {
                do {
                    let highlights = try await highlightStore.highlights(for: book.id)
                    descriptors.append(contentsOf: highlights.map {
                        RishiSpotlightDescriptor.highlight($0, book: book)
                    })
                } catch {
                    Log.error("spotlight.highlight_fetch_failed", error: error)
                }
            }
            descriptors.append(contentsOf: conversations.map(RishiSpotlightDescriptor.conversation))

            guard generation == indexGeneration,
                  await currentUserID() == userID else { return }
            try await replaceIndexItems(
                descriptors,
                userID: userID,
                generation: generation
            )
        } catch {
            Log.error("spotlight.reindex_failed", error: error)
        }
    }

    func transitionAccount(
        setIdentity: @escaping @MainActor @Sendable () async -> Bool
    ) async -> RishiSpotlightTransitionResult {
        indexGeneration &+= 1
        let generation = indexGeneration
        retryTask?.cancel()
        retryTask = nil
        cleanupPending = false
        suppressReindexAfterCleanup = false
        cleanupRequiredFor = nil
        cleanupRequiredGeneration = nil
        transitionInProgress = true
        transitionOwnerGeneration = generation
        let cleared = await clearIndex()

        guard generation == indexGeneration else {
            releaseTransition(generation: generation)
            return RishiSpotlightTransitionResult(identityApplied: false, cleanupComplete: false)
        }
        guard cleared else {
            cleanupPending = true
            cleanupRequiredFor = nil
            cleanupRequiredGeneration = generation
            releaseTransition(generation: generation)
            scheduleCleanupRetry()
            return RishiSpotlightTransitionResult(identityApplied: false, cleanupComplete: false)
        }
        let identityApplied = await setIdentity()
        guard identityApplied, generation == indexGeneration else {
            releaseTransition(generation: generation)
            return RishiSpotlightTransitionResult(identityApplied: false, cleanupComplete: false)
        }
        releaseTransition(generation: generation)
        await requestReindex()
        return RishiSpotlightTransitionResult(identityApplied: true, cleanupComplete: true)
    }

    func clearForAccountDeletion() async {
        indexGeneration &+= 1
        let generation = indexGeneration
        retryTask?.cancel()
        retryTask = nil
        cleanupPending = false
        suppressReindexAfterCleanup = true
        cleanupRequiredFor = nil
        cleanupRequiredGeneration = nil
        transitionInProgress = true
        transitionOwnerGeneration = generation
        let cleared = await clearIndex()
        guard generation == indexGeneration else {
            releaseTransition(generation: generation)
            return
        }
        if !cleared {
            guard generation == indexGeneration else {
                releaseTransition(generation: generation)
                return
            }
            cleanupPending = true
            // Account-deletion cleanup must continue after sign-out, so it
            // cannot be gated on the deleted user's now-nil identity.
            cleanupRequiredFor = nil
            cleanupRequiredGeneration = generation
            scheduleCleanupRetry()
        } else {
            cleanupPending = false
            suppressReindexAfterCleanup = false
            cleanupRequiredFor = nil
            cleanupRequiredGeneration = nil
        }
        releaseTransition(generation: generation)
    }

    private func releaseTransition(generation: UInt64) {
        guard transitionOwnerGeneration == generation else { return }
        transitionOwnerGeneration = nil
        transitionInProgress = false
    }

    private func clearIndex() async -> Bool {
        await operationGate.lock()
        do {
            try await indexingClient.deleteAll()
            await operationGate.unlock()
            return true
        } catch {
            await operationGate.unlock()
            Log.error("spotlight.clear_failed", error: error)
            return false
        }
    }

    private func replaceIndexItems(
        _ descriptors: [RishiSpotlightDescriptor],
        userID: UserID,
        generation: UInt64
    ) async throws {
        await operationGate.lock()
        do {
            guard generation == indexGeneration,
                  await currentUserID() == userID else {
                await operationGate.unlock()
                return
            }
            try await indexingClient.delete(domainIdentifiers: ["user:\(userID.uuidString)"])
            guard generation == indexGeneration,
                  await currentUserID() == userID else {
                await operationGate.unlock()
                return
            }
            try await indexingClient.index(descriptors)
            await operationGate.unlock()
        } catch {
            await operationGate.unlock()
            throw error
        }
    }

    private func retryCleanupIfNeeded() async -> Bool {
        guard cleanupPending else { return true }
        guard !cleanupRetryInProgress else { return false }
        guard let pendingGeneration = cleanupRequiredGeneration,
              indexGeneration == pendingGeneration else {
            return false
        }
        if let pendingUser = cleanupRequiredFor,
           await currentUserID() != pendingUser {
            return false
        }

        cleanupRetryInProgress = true
        defer { cleanupRetryInProgress = false }
        let delays: [UInt64] = [1, 4, 16]
        for (attempt, delay) in delays.enumerated() {
            guard !Task.isCancelled,
                  indexGeneration == pendingGeneration else { return false }
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled,
                  indexGeneration == pendingGeneration else { return false }
            if let pendingUser = cleanupRequiredFor,
               await currentUserID() != pendingUser {
                return false
            }
            if await clearIndex() {
                guard !Task.isCancelled,
                      indexGeneration == pendingGeneration else { return false }
                if let pendingUser = cleanupRequiredFor,
                   await currentUserID() != pendingUser {
                    return false
                }
                cleanupPending = false
                cleanupRequiredFor = nil
                cleanupRequiredGeneration = nil
                return true
            }
        }
        return false
    }

    private func scheduleCleanupRetry(after delay: Duration = .seconds(1)) {
        guard retryTask == nil else { return }
        let generation = cleanupRequiredGeneration
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.retryScheduledCleanup(generation: generation)
        }
    }

    private func retryScheduledCleanup(generation: UInt64?) async {
        retryTask = nil
        guard generation == cleanupRequiredGeneration, cleanupPending else { return }
        let suppressReindex = suppressReindexAfterCleanup
        if cleanupRetryInProgress {
            scheduleCleanupRetry()
            return
        }
        guard await retryCleanupIfNeeded() else {
            scheduleCleanupRetry(after: .seconds(60))
            return
        }
        if suppressReindex { return }
        await requestReindex()
    }
}

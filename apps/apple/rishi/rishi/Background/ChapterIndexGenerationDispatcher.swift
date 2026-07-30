import Foundation

/// Coordinates non-interactive chapter-index generation requests. Requests
/// arriving before the service graph finishes wiring are retained, and a book
/// can have at most one generation handler running at a time.
actor ChapterIndexGenerationDispatcher {
    typealias Handler = @Sendable (UUID) async -> Void

    private var handler: Handler?
    private var pending: Set<UUID> = []
    private var running: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var refreshAfterRun: Set<UUID> = []

    func configure(_ handler: @escaping Handler) {
        self.handler = handler
        let waiting = pending
        pending.removeAll()
        for bookID in waiting {
            launch(bookID, using: handler)
        }
    }

    func schedule(_ bookID: UUID) {
        guard let handler else {
            pending.insert(bookID)
            return
        }
        launch(bookID, using: handler)
    }

    /// Records that the source content changed while generation was running.
    /// The current task is allowed to finish, then one follow-up is started.
    func refresh(_ bookID: UUID) {
        guard let handler else {
            pending.insert(bookID)
            return
        }
        if running.contains(bookID) {
            refreshAfterRun.insert(bookID)
        } else {
            launch(bookID, using: handler)
        }
    }

    func schedule(_ bookIDs: [UUID]) {
        for bookID in bookIDs {
            schedule(bookID)
        }
    }

    /// Schedules the requested books and keeps the caller alive until the
    /// generation tasks that it owns have completed. Background-task launchers
    /// use this method; import callbacks use `schedule(_:)` instead.
    func run(_ bookIDs: [UUID]) async {
        while true {
            schedule(bookIDs)
            let ownedTasks = bookIDs.compactMap { tasks[$0] }
            for task in ownedTasks {
                if Task.isCancelled {
                    task.cancel()
                }
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            if !bookIDs.contains(where: { running.contains($0) || refreshAfterRun.contains($0) }) {
                return
            }
        }
    }

    private func launch(_ bookID: UUID, using handler: @escaping Handler) {
        guard running.insert(bookID).inserted else { return }
        let task = Task { [weak self] in
            await handler(bookID)
            await self?.finished(bookID)
        }
        tasks[bookID] = task
    }

    private func finished(_ bookID: UUID) {
        running.remove(bookID)
        tasks[bookID] = nil
        if refreshAfterRun.remove(bookID) != nil, let handler {
            launch(bookID, using: handler)
        }
    }
}

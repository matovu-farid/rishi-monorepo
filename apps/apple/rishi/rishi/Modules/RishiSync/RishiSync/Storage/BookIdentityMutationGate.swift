import Foundation

/// Serializes finite native commits for a book while allowing other books to
/// proceed. An exclusive account-reset request waits for entered commits.
actor BookIdentityMutationGate {
    private struct Waiter {
        let bookID: UUID?
        let token: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var protectedPositions: Set<UUID> = []
    func protectPosition(_ id: UUID) { protectedPositions.insert(id) }
    func releasePosition(_ id: UUID) { protectedPositions.remove(id) }
    func positionIsProtected(_ id: UUID) -> Bool { protectedPositions.contains(id) }
    func clearProtectedPositions() { protectedPositions.removeAll() }

    private var active: [UUID: UUID] = [:]
    private var exclusive: UUID?
    private var waiters: [Waiter] = []

    func withBook<T: Sendable>(_ id: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        let token = try await acquire(id)
        do {
            let value = try await operation()
            release(id, token: token)
            return value
        } catch {
            release(id, token: token)
            throw error
        }
    }

    func withExclusive<T: Sendable>(operation: @Sendable () async throws -> T) async throws -> T {
        let token = try await acquire(nil)
        do {
            let value = try await operation()
            release(nil, token: token)
            return value
        } catch {
            release(nil, token: token)
            throw error
        }
    }

    private func acquire(_ id: UUID?) async throws -> UUID {
        try Task.checkCancellation()
        let token = UUID()
        let admitted = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, Error>) in
                waiters.append(Waiter(bookID: id, token: token, continuation: continuation))
                advance()
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
        if Task.isCancelled {
            release(id, token: admitted)
            throw CancellationError()
        }
        return admitted
    }

    private func cancel(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        advance()
    }

    private func release(_ id: UUID?, token: UUID) {
        if let id {
            guard active[id] == token else { return }
            active[id] = nil
        } else {
            guard exclusive == token else { return }
            exclusive = nil
        }
        advance()
    }

    private func advance() {
        guard exclusive == nil else { return }
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard let id = waiter.bookID else {
                guard active.isEmpty else { return }
                exclusive = waiter.token
                waiters.remove(at: index).continuation.resume(returning: waiter.token)
                return
            }
            if active[id] == nil {
                active[id] = waiter.token
                waiters.remove(at: index).continuation.resume(returning: waiter.token)
            } else {
                index += 1
            }
        }
    }
}

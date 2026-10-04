import Foundation

/// Synchronous source-effect admission with asynchronous draining. The lock
/// protects only counters and never spans the admitted work itself.
public final class BookSourceEffectAuthority: BookSourceEffectAdmitting, @unchecked Sendable {
    private struct State {
        var open: Bool
        var active = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    public init() {}

    public func register(_ permit: BookSourceAccessPermit, open: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        states[permit.sourceInstanceID] = State(open: open)
    }

    public func admit(_ permit: BookSourceAccessPermit) throws -> SourceEffectAdmission {
        lock.lock()
        guard var state = states[permit.sourceInstanceID] else {
            lock.unlock()
            throw BookSourceAccessError.unknownSource
        }
        guard state.open else {
            lock.unlock()
            throw BookSourceAccessError.revoked
        }
        state.active += 1
        states[permit.sourceInstanceID] = state
        lock.unlock()
        return SourceEffectAdmission { [weak self] in self?.finish(permit) }
    }

    public func closeAdmission(_ permit: BookSourceAccessPermit) {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[permit.sourceInstanceID] else { return }
        state.open = false
        states[permit.sourceInstanceID] = state
    }

    public func drain(_ permit: BookSourceAccessPermit) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard var state = states[permit.sourceInstanceID] else {
                lock.unlock()
                continuation.resume()
                return
            }
            state.open = false
            if state.active == 0 {
                states.removeValue(forKey: permit.sourceInstanceID)
                lock.unlock()
                continuation.resume()
                return
            }
            state.drainWaiters.append(continuation)
            states[permit.sourceInstanceID] = state
            lock.unlock()
        }
    }

    private func finish(_ permit: BookSourceAccessPermit) {
        lock.lock()
        guard var state = states[permit.sourceInstanceID] else { lock.unlock(); return }
        state.active = max(0, state.active - 1)
        let waiters = state.active == 0 && !state.open ? state.drainWaiters : []
        if state.active == 0 && !state.open {
            states.removeValue(forKey: permit.sourceInstanceID)
        } else {
            states[permit.sourceInstanceID] = state
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

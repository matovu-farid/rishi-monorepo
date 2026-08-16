import Foundation

/// Synchronous account-transition fence. Callers obtain this before creating
/// their own asynchronous cleanup task; the drain itself starts only after
/// the identity and generation fence has been committed.
@MainActor
final class AccountChangeTransaction {
    let expectedAccountGeneration: UInt64
    let drain: Task<Void, Never>

    init(expectedAccountGeneration: UInt64, drain: Task<Void, Never>) {
        self.expectedAccountGeneration = expectedAccountGeneration
        self.drain = drain
    }
}

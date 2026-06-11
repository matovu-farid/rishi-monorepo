import Foundation
import StoreKit
import RishiLogging

// MARK: - Forwarder seam

/// Sink for `Transaction.updates` events the ``TransactionListener``
/// observes. ``PurchaseService`` is the production conformer; tests inject
/// a mock to assert listener wiring without driving an end-to-end
/// SKTestSession purchase.
public protocol PurchaseUpdateForwarder: Sendable {
    func processUpdate(
        _ result: VerificationResult<Transaction>,
        source: String
    ) async
}

// MARK: - Listener actor

/// Long-lived wrapper around the `Transaction.updates` async sequence.
///
/// Installed once from `AppDependencies.init()` (per CONTEXT) and lives the
/// entire app lifetime. Catches:
/// - server-initiated renewals,
/// - refunds (`transaction.revocationDate != nil`),
/// - subscription state changes,
/// - any purchase completed off-device (Family Sharing, App Store retry of
///   a pending purchase).
///
/// **Concurrency:** the for-await loop runs in a detached background-priority
/// Task so it never inherits MainActor isolation (RESEARCH §10 Pitfall 12).
/// The forwarder bears the responsibility for hopping back to MainActor when
/// updating UI state.
public actor TransactionListener {

    private let forwarder: any PurchaseUpdateForwarder
    private var updatesTask: Task<Void, Never>?

    public init(forwarder: any PurchaseUpdateForwarder) {
        self.forwarder = forwarder
    }

    /// Whether the listener Task is currently installed. Internal accessor
    /// exposed for tests; not part of the public lifecycle contract.
    public var isRunning: Bool { updatesTask != nil }

    /// Install the listener Task. Safe to re-call; subsequent calls no-op
    /// (RESEARCH §3.2 listener lifecycle).
    public func start() {
        guard updatesTask == nil else { return }
        let forwarder = self.forwarder
        updatesTask = Task.detached(priority: .background) {
            for await update in Transaction.updates {
                await forwarder.processUpdate(update, source: "updates")
            }
        }
        Log.event("iap.listener.started", level: .info)
    }

    /// Cancel the listener Task. Safe to re-call.
    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        Log.event("iap.listener.stopped", level: .info)
    }

    deinit {
        // AppDependencies holds a strong reference for the entire app
        // lifetime; deinit is effectively never called. We can't await /
        // cancel from a deinit on an actor cleanly, so the Task naturally
        // ends when the process terminates.
    }
}

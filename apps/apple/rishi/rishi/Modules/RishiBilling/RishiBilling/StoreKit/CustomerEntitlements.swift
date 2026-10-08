import Foundation
import OSLog
import StoreKit

private let logger = Logger(subsystem: "Rishi", category: "CustomerEntitlements")
public typealias SubscriptionGroupID = String

@available(iOS 18.4, macOS 15.4, *)
@MainActor @Observable
public final class CustomerEntitlements {
    private let authority: SessionCredentialAuthority
    private let syncClient: EntitlementSyncClient
    private let worker: WorkerClient
    private let refreshCoordinator: EntitlementRefreshCoordinator
    private let sources: CustomerEntitlementSources
    private var observationGeneration: UUID?
    private var transactionUpdatesTask: Task<Void, Never>?
    private var statusUpdatesTask: Task<Void, Never>?
    private var initialCheckTask: Task<Void, Never>?
    private var inFlightTransactionIds: Set<UInt64> = []
    private var errorOwner: CredentialLease?
    public private(set) var subscriptionStatuses: [SubscriptionGroupID: [SubscriptionStatus]] = [:]
    public private(set) var error: CustomerEntitlementsError?

    init(credentialAuthority: SessionCredentialAuthority,
         entitlementSyncClient: EntitlementSyncClient, workerClient: WorkerClient,
         refreshCoordinator: EntitlementRefreshCoordinator,
         sources: CustomerEntitlementSources = .storeKit) throws {
        guard entitlementSyncClient.usesCredentialAuthority(credentialAuthority),
              workerClient.usesCredentialAuthority(credentialAuthority),
              refreshCoordinator.usesCredentialAuthority(credentialAuthority) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        authority = credentialAuthority
        syncClient = entitlementSyncClient
        worker = workerClient
        self.refreshCoordinator = refreshCoordinator
        self.sources = sources
    }

    isolated deinit {
        transactionUpdatesTask?.cancel()
        statusUpdatesTask?.cancel()
        initialCheckTask?.cancel()
    }

    /// One app/service-graph lifecycle. Multiple scenes can repeat start;
    /// only graph retirement stops it.
    func startObserving() {
        guard observationGeneration == nil else { return }
        let generation = UUID()
        observationGeneration = generation
        let transactionUpdate: CustomerEntitlementSources.Callback = { [weak self] event in
            guard let self, self.observationGeneration == generation, !Task.isCancelled else { return }
            await self.receive(event, origin: .purchaseCompletion, verifyAfterSync: true)
        }
        let backgroundUpdate: CustomerEntitlementSources.Callback = { [weak self] event in
            guard let self, self.observationGeneration == generation, !Task.isCancelled else { return }
            await self.receive(event, origin: .backgroundSync, verifyAfterSync: false)
        }
        let sources = sources
        transactionUpdatesTask = Task { await sources.transactions(transactionUpdate) }
        statusUpdatesTask = Task { await sources.statuses(backgroundUpdate) }
        // Owned initial work never prevents either updates stream starting.
        initialCheckTask = Task { await sources.initial(backgroundUpdate) }
    }

    func stopObserving() {
        observationGeneration = nil
        transactionUpdatesTask?.cancel(); transactionUpdatesTask = nil
        statusUpdatesTask?.cancel(); statusUpdatesTask = nil
        initialCheckTask?.cancel(); initialCheckTask = nil
    }

    func clearAccountProjection(lease: CredentialLease) {
        guard errorOwner == lease else { return }
        error = nil; errorOwner = nil
    }

    func isCurrent(_ context: CredentialRequestContext?) -> Bool {
        guard case .some(.normal(let lease)) = context else { return false }
        return authority.isCurrent(lease)
    }

    public func hasActiveSubscription(in groupID: SubscriptionGroupID) -> Bool {
        subscriptionStatuses[groupID]?.activeSubscriptionStatuses.isEmpty == false
    }

    public func activeProductID(in groupID: SubscriptionGroupID) -> Product.ID? {
        subscriptionStatuses[groupID]?.activeSubscriptionStatuses
            .sorted { $0.transaction.unsafePayloadValue.purchaseDate > $1.transaction.unsafePayloadValue.purchaseDate }
            .first?.transaction.unsafePayloadValue.productID
    }

    func process(transaction: Transaction, jws: String,
                 origin: EntitlementProcessOrigin = .backgroundSync,
                 credentialContext: CredentialRequestContext) async {
        await process(receipt: .init(transaction: transaction, jws: jws), origin: origin,
                      credentialContext: credentialContext)
    }

    func process(receipt: CustomerEntitlementReceipt, origin: EntitlementProcessOrigin,
                 credentialContext: CredentialRequestContext) async {
        guard isCurrent(credentialContext), !Task.isCancelled,
              inFlightTransactionIds.insert(receipt.id).inserted else { return }
        let generation = observationGeneration
        defer { inFlightTransactionIds.remove(receipt.id) }
        do {
            let result = try await syncClient.sync(transactionJWS: receipt.jws, credentialContext: credentialContext)
            if result.verified, isCurrent(credentialContext), !Task.isCancelled {
                _ = await refreshCoordinator.refreshIfSignedIn(reason: .foreground, credentialContext: credentialContext)
            }
            // Deliver the committed original HTTP result even after retirement.
            await receipt.finish()
            if !result.verified {
                logger.error("Entitlement sync rejected \(receipt.id): \(result.reason ?? "unknown")")
                surfaceFailure(receipt, origin: origin, context: credentialContext, generation: generation)
            }
        } catch {
            logger.error("Entitlement sync failed for \(receipt.id); leaving unfinished: \(error)")
            surfaceFailure(receipt, origin: origin, context: credentialContext, generation: generation)
        }
    }

    private func surfaceFailure(_ receipt: CustomerEntitlementReceipt, origin: EntitlementProcessOrigin,
                                context: CredentialRequestContext, generation: UUID?) {
        guard origin == .purchaseCompletion, !receipt.isXcode, observationGeneration == generation,
              isCurrent(context), !Task.isCancelled else { return }
        setError(.entitlementSyncFailed, context: context)
    }

    private func setError(_ next: CustomerEntitlementsError, context: CredentialRequestContext) {
        guard case .normal(let lease) = context, authority.isCurrent(lease) else { return }
        error = next; errorOwner = lease
    }

    private func receive(_ event: CustomerEntitlementEvent, origin: EntitlementProcessOrigin,
                         verifyAfterSync: Bool) async {
        // Capture before the first verification/transport suspension. Device
        // status remains a management projection even while signed out.
        let context = (try? authority.snapshot()).map { CredentialRequestContext.normal($0.lease) }
        switch event {
        case .receipt(let receipt):
            guard let context else { return }
            await process(receipt: receipt, origin: origin, credentialContext: context)
            guard verifyAfterSync, isCurrent(context), !Task.isCancelled else { return }
            do {
                _ = try await worker.send(VerifyEndPont(body: .init(transactionId: receipt.id)), credentialContext: context)
            } catch { logger.error("Best-effort transaction verification failed: \(error)") }
        case .invalid:
            if let context { setError(.invalidTransaction, context: context) }
        case .currentStatuses(let group, let statuses):
            subscriptionStatuses[group] = statuses
            if let context { _ = await refreshCoordinator.refreshIfSignedIn(reason: .foreground, credentialContext: context) }
        case .statusUpdate(let status):
            switch status.transaction {
            case .unverified(_, let failure):
                logger.error("Unverified subscription status: \(failure)")
                if let context { setError(.invalidTransaction, context: context) }
            case .verified(let transaction):
                guard let group = transaction.subscriptionGroupID else { return }
                let current = subscriptionStatuses[group] ?? []
                subscriptionStatuses[group] = current.filter {
                    $0.transaction.unsafePayloadValue.ownershipType != transaction.ownershipType
                } + [status]
                if let context { _ = await refreshCoordinator.refreshIfSignedIn(reason: .foreground, credentialContext: context) }
            }
        }
    }
}

@available(iOS 18.4, macOS 15.4, *)
enum CustomerEntitlementEvent {
    case receipt(CustomerEntitlementReceipt)
    case invalid
    case currentStatuses(String, [SubscriptionStatus])
    case statusUpdate(SubscriptionStatus)
}

/// Native sequence adapters and finite test seams. This value owns no tasks,
/// caches, account lifetime, or entitlement state.
@available(iOS 18.4, macOS 15.4, *)
struct CustomerEntitlementSources: Sendable {
    typealias Callback = @MainActor @Sendable (CustomerEntitlementEvent) async -> Void
    let transactions: @MainActor @Sendable (@escaping Callback) async -> Void
    let statuses: @MainActor @Sendable (@escaping Callback) async -> Void
    let initial: @MainActor @Sendable (@escaping Callback) async -> Void

    static let storeKit = Self(
        transactions: { callback in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await callback(event(result))
            }
        },
        statuses: { callback in
            for await status in SubscriptionStatus.updates {
                guard !Task.isCancelled else { return }
                await callback(.statusUpdate(status))
            }
        },
        initial: { callback in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                let next = event(result); await callback(next)
                if case .invalid = next { break }
            }
            for await result in Transaction.currentEntitlements {
                guard !Task.isCancelled else { return }
                let next = event(result); await callback(next)
                if case .invalid = next { break }
            }
            for await (group, statuses) in SubscriptionStatus.all {
                guard !Task.isCancelled else { return }
                await callback(.currentStatuses(group, statuses))
            }
        }
    )

    private static func event(_ result: VerificationResult<Transaction>) -> CustomerEntitlementEvent {
        switch result {
        case .verified(let transaction): return .receipt(.init(transaction: transaction, jws: result.jwsRepresentation))
        case .unverified(let transaction, let error):
            logger.error("Unverified transaction \(transaction.id): \(error)")
            return .invalid
        }
    }
}

/// Immutable input and original StoreKit completion capability. Native and
/// memory-only regression tests share the same finite receipt processing path.
@available(iOS 18.4, macOS 15.4, *)
struct CustomerEntitlementReceipt: Sendable {
    let id: UInt64
    let productID: String
    let jws: String
    let isXcode: Bool
    let finish: @Sendable () async -> Void

    init(id: UInt64, productID: String, jws: String, isXcode: Bool,
         finish: @escaping @Sendable () async -> Void) {
        self.id = id; self.productID = productID; self.jws = jws
        self.isXcode = isXcode; self.finish = finish
    }

    init(transaction: Transaction, jws: String) {
        self.init(id: transaction.id, productID: transaction.productID, jws: jws,
                  isXcode: transaction.environment == .xcode, finish: { await transaction.finish() })
    }
}

/// Why ``CustomerEntitlements/process(transaction:jws:origin:)`` was invoked.
/// Controls whether a failed sync surfaces a user-facing error.
public enum EntitlementProcessOrigin: Sendable {
    /// Same-session purchase completion, including `Transaction.updates`
    /// for live purchase / Ask-to-Buy resolution.
    case purchaseCompletion
    /// `Transaction.currentEntitlements` or `Transaction.unfinished` replay.
    case backgroundSync
}

public enum CustomerEntitlementsError: Error, Equatable {
    case invalidTransaction
    case failedToFetchPersistedData
    case failedToUpdatePersistedData
    /// Worker entitlement-sync failed (transport) or returned verified:false
    /// (business reject). Transport leaves the transaction unfinished;
    /// verified:false finishes it (unretriable for this JWS).
    case entitlementSyncFailed
}


@available(iOS 18.4, macOS 15.4, *)
extension Sequence where Element == SubscriptionStatus {
    public var activeSubscriptionStatuses: [SubscriptionStatus] {
        filter {
            $0.state == .subscribed || $0.state == .inGracePeriod || $0.state == .inBillingRetryPeriod
        }
    }
    
    public var highestSubscriptionStatus: SubscriptionStatus? {
        get throws {

            return self.first(where: {
                EntitlementLevel.initialize(productId: $0.transaction.unsafePayloadValue.productID) == .subscribed

            })
        }
    }
    
 
}

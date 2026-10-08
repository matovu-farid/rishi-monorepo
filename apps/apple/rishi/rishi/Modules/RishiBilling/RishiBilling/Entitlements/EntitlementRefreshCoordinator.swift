import Foundation


/// Coalesces entitlement refresh work across launch, foreground, sign-in, and
/// AI feature gates.
@available(iOS 18.4, macOS 15.4, *)
public actor EntitlementRefreshCoordinator {
    public enum RefreshReason: Sendable {
        case launch
        case foreground
        case signIn
        case aiFeatureTap
    }

    private let credentialAuthority: SessionCredentialAuthority?
    nonisolated func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool {
        credentialAuthority === authority
    }

    private let entitlementService: EntitlementService
    private let launchRefresh: @Sendable (RefreshOwner) async -> Void
    private enum RefreshOwner: Equatable, Sendable {
        case legacy(String)
        case credential(CredentialLease)

    }
    private let signedInOwnerProvider: @Sendable () -> RefreshOwner?
    private struct InFlightRefresh {
        let id: UUID
        let owner: RefreshOwner
        let includesLaunchRefresh: Bool
        let task: Task<Result<EntitlementSnapshot, Error>, Never>
    }
    private struct LaunchPromotion {
        let id: UUID
        let sourceID: UUID
        let task: Task<Result<EntitlementSnapshot, Error>, Never>
    }
    private struct EarlyLaunchGeneration {
        let id: UUID
        let owner: RefreshOwner
        let task: Task<Result<EntitlementSnapshot, Error>, Never>
    }

    private var inFlightRefresh: InFlightRefresh?
    private var launchPromotions: [UUID: LaunchPromotion] = [:]
    // Only spans an early account-change launch generation; the task clears it
    // when reconciliation completes so it cannot become a stale result cache.
    private var earlyLaunchGeneration: EarlyLaunchGeneration?

    public init(
        entitlementService: EntitlementService,
        launchRefresh: any EntitlementLaunchRefresh,
        signedInUserIdProvider: @escaping @Sendable () -> String?
    ) {
        self.credentialAuthority = nil
        self.entitlementService = entitlementService
        self.launchRefresh = { _ in await launchRefresh.refreshOnDeviceEntitlementAtLaunch() }
        self.signedInOwnerProvider = { signedInUserIdProvider().map(RefreshOwner.legacy) }
    }

    init(
        entitlementService: EntitlementService,
        launchRefresh: any CredentialBoundEntitlementLaunchRefresh,
        credentialAuthority: SessionCredentialAuthority
    ) throws {
        guard launchRefresh.usesCredentialAuthority(credentialAuthority),
              entitlementService.usesCredentialAuthority(credentialAuthority) else {
            throw CredentialAuthenticationFailure.accountChanged
        }
        self.credentialAuthority = credentialAuthority
        self.entitlementService = entitlementService
        self.launchRefresh = { owner in
            guard case .credential(let lease) = owner else { return }
            await launchRefresh.refreshOnDeviceEntitlementAtLaunch(credentialContext: .normal(lease))
        }
        signedInOwnerProvider = { (try? credentialAuthority.snapshot()).map { .credential($0.lease) } }
    }

    /// Refresh snapshot and on-device entitlement when a user is signed in.
    public func refreshIfSignedIn(
        reason: RefreshReason = .foreground,
        force: Bool = false
    ) async -> Result<EntitlementSnapshot, Error>? {
        guard let requestedOwner = signedInOwnerProvider() else { return nil }
        return await refresh(reason: reason, force: force, requestedOwner: requestedOwner)
    }

    /// Explicit account admission is validated after the actor hop. A delayed
    /// completion cannot refresh the account that replaced its original owner.
    func refreshIfSignedIn(reason: RefreshReason = .foreground, force: Bool = false,
                           credentialContext: CredentialRequestContext) async -> Result<EntitlementSnapshot, Error>? {
        guard case .normal(let lease) = credentialContext,
              let credentialAuthority, credentialAuthority.isCurrent(lease),
              signedInOwnerProvider() == .credential(lease) else {
            return .failure(EntitlementRefreshError.accountChanged)
        }
        return await refresh(reason: reason, force: force, requestedOwner: .credential(lease))
    }

    private func refresh(reason: RefreshReason, force: Bool,
                         requestedOwner: RefreshOwner) async -> Result<EntitlementSnapshot, Error>? {
        // Forced work still coalesces for the same original account.
        _ = force
        while true {
            guard signedInOwnerProvider() == requestedOwner else {
                return await accountChangedResult(
                    expectedOwner: requestedOwner,
                    reason: reason
                )
            }

            if reason == .launch,
               let early = earlyLaunchGeneration,
               early.owner == requestedOwner {
                let result = await early.task.value
                return revalidate(result, expectedOwner: requestedOwner)
            }

            if let current = inFlightRefresh {
                if current.owner != requestedOwner {
                    _ = await current.task.value
                    clearInFlightIfMatching(current.id)
                    guard signedInOwnerProvider() == requestedOwner else {
                        return await accountChangedResult(
                            expectedOwner: requestedOwner,
                            reason: reason
                        )
                    }
                    continue
                }

                if reason == .launch && !current.includesLaunchRefresh {
                    let result = await launchPromotionResult(
                        source: current,
                        expectedOwner: requestedOwner
                    )
                    return revalidate(result, expectedOwner: requestedOwner)
                }

                let result = await current.task.value
                guard signedInOwnerProvider() == requestedOwner else {
                    return .failure(EntitlementRefreshError.accountChanged)
                }
                return revalidate(result, expectedOwner: requestedOwner)
            }

            let created = makeInFlightRefresh(
                owner: requestedOwner,
                reason: reason
            )
            inFlightRefresh = created
            let result = await created.task.value
            clearInFlightIfMatching(created.id)
            guard signedInOwnerProvider() == requestedOwner else {
                return .failure(EntitlementRefreshError.accountChanged)
            }
            return revalidate(result, expectedOwner: requestedOwner)
        }
    }

    private func launchPromotionResult(
        source: InFlightRefresh,
        expectedOwner: RefreshOwner
    ) async -> Result<EntitlementSnapshot, Error> {
        if let existing = launchPromotions[source.id] {
            return await existing.task.value
        }

        let promotionID = UUID()
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [self] in
            let result = await self.performLaunchPromotion(
                source: source,
                expectedOwner: expectedOwner
            )
            await self.clearLaunchPromotionIfMatching(
                sourceID: source.id,
                promotionID: promotionID
            )
            return result
        }
        launchPromotions[source.id] = LaunchPromotion(
            id: promotionID,
            sourceID: source.id,
            task: task
        )
        return await task.value
    }

    private func performLaunchPromotion(
        source: InFlightRefresh,
        expectedOwner: RefreshOwner
    ) async -> Result<EntitlementSnapshot, Error> {
        _ = await source.task.value

        while true {
            guard signedInOwnerProvider() == expectedOwner else {
                return await accountChangedResult(
                    expectedOwner: expectedOwner,
                    reason: .launch
                )
            }

            guard let current = inFlightRefresh else {
                let created = makeInFlightRefresh(
                    owner: expectedOwner,
                    reason: .launch
                )
                inFlightRefresh = created
                let result = await created.task.value
                clearInFlightIfMatching(created.id)
                return result
            }

            if current.owner != expectedOwner {
                _ = await current.task.value
                await Task.yield()
                continue
            }

            if current.id == source.id {
                let promoted = makeInFlightRefresh(
                    owner: expectedOwner,
                    reason: .launch
                )
                inFlightRefresh = promoted
                let result = await promoted.task.value
                clearInFlightIfMatching(promoted.id)
                return result
            }

            if current.includesLaunchRefresh {
                return await current.task.value
            }

            _ = await current.task.value
            await Task.yield()
        }
    }

    private func clearLaunchPromotionIfMatching(
        sourceID: UUID,
        promotionID: UUID
    ) {
        guard launchPromotions[sourceID]?.id == promotionID else { return }
        launchPromotions[sourceID] = nil
    }

    private func accountChangedResult(
        expectedOwner: RefreshOwner,
        reason: RefreshReason
    ) async -> Result<EntitlementSnapshot, Error> {
        guard reason == .launch else {
            return .failure(EntitlementRefreshError.accountChanged)
        }

        if let existing = earlyLaunchGeneration,
           existing.owner == expectedOwner {
            return await existing.task.value
        }

        let reconciliationID = UUID()
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [launchRefresh, self] in
            await launchRefresh(expectedOwner)
            await self.clearEarlyLaunchGenerationIfMatching(reconciliationID)
            return .failure(EntitlementRefreshError.accountChanged)
        }
        earlyLaunchGeneration = EarlyLaunchGeneration(
            id: reconciliationID,
            owner: expectedOwner,
            task: task
        )
        return await task.value
    }

    private func makeInFlightRefresh(
        owner: RefreshOwner,
        reason: RefreshReason
    ) -> InFlightRefresh {
        let id = UUID()
        let includesLaunchRefresh = reason == .launch
        let ownerProvider = signedInOwnerProvider
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [entitlementService, launchRefresh, ownerProvider] in
            let result: Result<EntitlementSnapshot, Error>
            if ownerProvider() == owner {
                switch owner {
                case .legacy(let userId):
                    await entitlementService.bindToUser(userId: userId)
                    result = await entitlementService.refreshSnapshot(
                        expectedUserId: userId,
                        isCurrentUser: { ownerProvider() == owner }
                    )
                case .credential(let lease):
                    if await entitlementService.bindToUser(userId: lease.rawUserID, lease: lease) {
                        result = await entitlementService.refreshSnapshot(lease: lease)
                    } else {
                        result = .failure(EntitlementRefreshError.accountChanged)
                    }
                }
            } else {
                result = .failure(EntitlementRefreshError.accountChanged)
            }

            if includesLaunchRefresh {
                await launchRefresh(owner)
            }
            return result
        }

        return InFlightRefresh(
            id: id,
            owner: owner,
            includesLaunchRefresh: includesLaunchRefresh,
            task: task
        )
    }

    private func clearInFlightIfMatching(_ id: UUID) {
        guard inFlightRefresh?.id == id else { return }
        inFlightRefresh = nil
    }

    private func clearEarlyLaunchGenerationIfMatching(_ id: UUID) {
        guard earlyLaunchGeneration?.id == id else { return }
        earlyLaunchGeneration = nil
    }

    private func revalidate(
        _ result: Result<EntitlementSnapshot, Error>,
        expectedOwner: RefreshOwner
    ) -> Result<EntitlementSnapshot, Error>? {
        guard let currentOwner = signedInOwnerProvider() else { return nil }
        guard currentOwner == expectedOwner else {
            return .failure(EntitlementRefreshError.accountChanged)
        }
        return result
    }
}

/// Abstraction for launch-time StoreKit / restore refresh so RishiBilling
/// tests can inject a no-op.
@available(iOS 18.4, macOS 15.4, *)
public protocol EntitlementLaunchRefresh: Sendable {
    func refreshOnDeviceEntitlementAtLaunch() async
}

/// Required normal-account launch admission; no ambient fallback/default.
@available(iOS 18.4, macOS 15.4, *)
protocol CredentialBoundEntitlementLaunchRefresh: EntitlementLaunchRefresh {
    func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool
    func refreshOnDeviceEntitlementAtLaunch(credentialContext: CredentialRequestContext) async
}

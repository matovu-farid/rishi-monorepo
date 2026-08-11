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

    private let entitlementService: EntitlementService
    private let launchRefresh: any EntitlementLaunchRefresh
    private let signedInUserIdProvider: @Sendable () -> String?
    private struct InFlightRefresh {
        let id: UUID
        let userId: String
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
        let userId: String
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
        self.entitlementService = entitlementService
        self.launchRefresh = launchRefresh
        self.signedInUserIdProvider = signedInUserIdProvider
    }

    /// Refresh snapshot and on-device entitlement when a user is signed in.
    public func refreshIfSignedIn(
        reason: RefreshReason = .foreground,
        force: Bool = false
    ) async -> Result<EntitlementSnapshot, Error>? {
        // Force requests still coalesce with same-account work. The force
        // flag is retained for source compatibility and caller intent, while
        // Task 2 requires one shared in-flight refresh per account.
        _ = force
        guard let requestedUserId = signedInUserIdProvider() else { return nil }

        while true {
            guard signedInUserIdProvider() == requestedUserId else {
                return await accountChangedResult(
                    expectedUserId: requestedUserId,
                    reason: reason
                )
            }

            if reason == .launch,
               let early = earlyLaunchGeneration,
               early.userId == requestedUserId {
                let result = await early.task.value
                return revalidate(result, expectedUserId: requestedUserId)
            }

            if let current = inFlightRefresh {
                if current.userId != requestedUserId {
                    let result = await current.task.value
                    guard signedInUserIdProvider() == requestedUserId else {
                        return await accountChangedResult(
                            expectedUserId: requestedUserId,
                            reason: reason
                        )
                    }
                    continue
                }

                if reason == .launch && !current.includesLaunchRefresh {
                    let result = await launchPromotionResult(
                        source: current,
                        expectedUserId: requestedUserId
                    )
                    return revalidate(result, expectedUserId: requestedUserId)
                }

                let result = await current.task.value
                guard signedInUserIdProvider() == requestedUserId else {
                    return .failure(EntitlementRefreshError.accountChanged)
                }
                return revalidate(result, expectedUserId: requestedUserId)
            }

            let created = makeInFlightRefresh(
                userId: requestedUserId,
                reason: reason
            )
            inFlightRefresh = created
            let result = await created.task.value
            clearInFlightIfMatching(created.id)
            guard signedInUserIdProvider() == requestedUserId else {
                return .failure(EntitlementRefreshError.accountChanged)
            }
            return revalidate(result, expectedUserId: requestedUserId)
        }
    }

    private func launchPromotionResult(
        source: InFlightRefresh,
        expectedUserId: String
    ) async -> Result<EntitlementSnapshot, Error> {
        if let existing = launchPromotions[source.id] {
            return await existing.task.value
        }

        let promotionID = UUID()
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [self] in
            let result = await self.performLaunchPromotion(
                source: source,
                expectedUserId: expectedUserId
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
        expectedUserId: String
    ) async -> Result<EntitlementSnapshot, Error> {
        _ = await source.task.value

        while true {
            guard signedInUserIdProvider() == expectedUserId else {
                return await accountChangedResult(
                    expectedUserId: expectedUserId,
                    reason: .launch
                )
            }

            guard let current = inFlightRefresh else {
                let created = makeInFlightRefresh(
                    userId: expectedUserId,
                    reason: .launch
                )
                inFlightRefresh = created
                let result = await created.task.value
                clearInFlightIfMatching(created.id)
                return result
            }

            if current.userId != expectedUserId {
                _ = await current.task.value
                await Task.yield()
                continue
            }

            if current.id == source.id {
                let promoted = makeInFlightRefresh(
                    userId: expectedUserId,
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
        expectedUserId: String,
        reason: RefreshReason
    ) async -> Result<EntitlementSnapshot, Error> {
        guard reason == .launch else {
            return .failure(EntitlementRefreshError.accountChanged)
        }

        if let existing = earlyLaunchGeneration,
           existing.userId == expectedUserId {
            return await existing.task.value
        }

        let reconciliationID = UUID()
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [launchRefresh, self] in
            await launchRefresh.refreshOnDeviceEntitlementAtLaunch()
            await self.clearEarlyLaunchGenerationIfMatching(reconciliationID)
            return .failure(EntitlementRefreshError.accountChanged)
        }
        earlyLaunchGeneration = EarlyLaunchGeneration(
            id: reconciliationID,
            userId: expectedUserId,
            task: task
        )
        return await task.value
    }

    private func makeInFlightRefresh(
        userId: String,
        reason: RefreshReason
    ) -> InFlightRefresh {
        let id = UUID()
        let includesLaunchRefresh = reason == .launch
        let userIdProvider = signedInUserIdProvider
        let task: Task<Result<EntitlementSnapshot, Error>, Never> = Task {
            [entitlementService, launchRefresh, userIdProvider] in
            let result: Result<EntitlementSnapshot, Error>
            if userIdProvider() == userId {
                await entitlementService.bindToUser(userId: userId)
                result = await entitlementService.refreshSnapshot(
                    expectedUserId: userId,
                    isCurrentUser: { userIdProvider() == userId }
                )
            } else {
                result = .failure(EntitlementRefreshError.accountChanged)
            }

            if includesLaunchRefresh {
                await launchRefresh.refreshOnDeviceEntitlementAtLaunch()
            }
            return result
        }

        return InFlightRefresh(
            id: id,
            userId: userId,
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
        expectedUserId: String
    ) -> Result<EntitlementSnapshot, Error>? {
        guard let currentUserId = signedInUserIdProvider() else { return nil }
        guard currentUserId == expectedUserId else {
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

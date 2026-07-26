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
    private var inFlightRefresh: Task<Void, Never>?

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
    ) async {
        guard signedInUserIdProvider() != nil else { return }

        if let inFlightRefresh, !force {
            await inFlightRefresh.value
            return
        }

        if force, let inFlightRefresh {
            await inFlightRefresh.value
        }

        let userIdProvider = signedInUserIdProvider
        let task = Task { [entitlementService, launchRefresh, reason, userIdProvider] in
            if let userId = userIdProvider() {
                await entitlementService.bindToUser(userId: userId)
            }
            _ = await entitlementService.refreshSnapshot()
            if reason == .launch {
                await launchRefresh.refreshOnDeviceEntitlementAtLaunch()
            }
        }
        inFlightRefresh = task
        await task.value
        inFlightRefresh = nil
    }
}

/// Abstraction for launch-time StoreKit / restore refresh so RishiBilling
/// tests can inject a no-op.
@available(iOS 18.4, macOS 15.4, *)
public protocol EntitlementLaunchRefresh: Sendable {
    func refreshOnDeviceEntitlementAtLaunch() async
}

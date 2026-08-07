import StoreKit
import SwiftUI

struct SubscriptionPaywallPresentation: Equatable {
    enum Action: Equatable {
        case subscribe
        case manage
    }

    let action: Action
    let visibleRelationships: Product.SubscriptionRelationship

    var showsRestorePurchases: Bool {
        action == .subscribe
    }

    init(isPaidActive: Bool) {
        action = isPaidActive ? .manage : .subscribe
        visibleRelationships = isPaidActive ? .upgrade : .all
    }
}

enum RestoreMessage {
    static func forOutcome(_ outcome: RestoreOutcome) -> String {
        switch outcome {
        case .restored:
            return "Purchases restored."
        case .nothingToRestore:
            return "No purchases were found to restore."
        }
    }

    static func forError(_ error: RestoreError) -> String {
        switch error {
        case .syncFailed, .entitlementSyncFailed:
            return "We couldn’t verify your purchases right now. Check your Apple ID connection and try again."
        }
    }
}

public struct SubscriptionDependencies {
    public let groupID: GroupId?
    public let entitlementRefreshCoordinator: EntitlementRefreshCoordinator
    public let restoreService: RestoreService

    public init(
        groupID: GroupId?,
        entitlementRefreshCoordinator: EntitlementRefreshCoordinator,
        restoreService: RestoreService
    ) {
        self.groupID = groupID
        self.entitlementRefreshCoordinator = entitlementRefreshCoordinator
        self.restoreService = restoreService
    }
}

public struct SubscriptionsView: View {
    @Environment(Store.self) private var store
    @Environment(\.services) private var services
    @Environment(EntitlementSnapshotStore.self) private var entitlementStore
    private let dependencies: SubscriptionDependencies?
    @State private var customerEntitlements = CustomerEntitlements.shared
    @State private var hasSession: Bool?
    @State private var tokenError = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    /// Preloaded `appAccountToken` — only non-nil after a confirmed session.
    /// Used so `.inAppPurchaseOptions` never returns `[]` (which would allow
    /// a purchase without account binding; that API is non-throwing).
    @State private var appAccountToken: UUID?

    private let onPurchaseCompleted: () -> Void
    private let onPurchaseProcessed: @MainActor () async -> Void

    private var isPaidActive: Bool {
        let serverPaid = entitlementStore.resolvedSnapshot?.isPaidActive == true
        let storeKitPaid = groupID.map {
            customerEntitlements.hasActiveSubscription(in: $0.value)
        } ?? false
        return serverPaid || storeKitPaid
    }

    private var activeProductID: Product.ID? {
        guard let productID = groupID.flatMap({
            customerEntitlements.activeProductID(in: $0.value)
        }) else { return nil }
        #if targetEnvironment(macCatalyst)
        return RishiProductID.macCatalystEquivalentProductID(for: productID)
        #else
        return productID
        #endif
    }

    public init(
        dependencies: SubscriptionDependencies,
        onPurchaseCompleted: @escaping () -> Void = {},
        onPurchaseProcessed: @escaping @MainActor () async -> Void = {}
    ) {
        self.dependencies = dependencies
        self.onPurchaseCompleted = onPurchaseCompleted
        self.onPurchaseProcessed = onPurchaseProcessed
    }

    public init(
        onPurchaseCompleted: @escaping () -> Void = {},
        onPurchaseProcessed: @escaping @MainActor () async -> Void = {}
    ) {
        self.dependencies = nil
        self.onPurchaseCompleted = onPurchaseCompleted
        self.onPurchaseProcessed = onPurchaseProcessed
    }

    private var groupID: GroupId? {
        dependencies?.groupID ?? services?.billing.groupID
    }

    private var entitlementRefreshCoordinator: EntitlementRefreshCoordinator? {
        dependencies?.entitlementRefreshCoordinator ?? services?.billing.entitlementRefreshCoordinator
    }

    private var restoreService: RestoreService? {
        dependencies?.restoreService ?? services?.billing.restoreService
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                RishiColor.accent
                    .opacity(0.1)
                    .ignoresSafeArea()
                content
            }
            .task {
                guard let session = try? await KeychainSessionStore().load() else {
                    hasSession = false
                    appAccountToken = nil
                    return
                }
                appAccountToken = AppAccountToken.derive(userId: session.userId)
                hasSession = true
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(
            minWidth: 880,
            idealWidth: 880,
            minHeight: 1_000,
            idealHeight: 1_000
        )
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.loadState == .failed {
            ContentUnavailableView {
                Label("Plans unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Subscription plans could not be loaded. Check your connection and retry.")
            } actions: {
                Button("Retry") {
                    Task { await store.loadProducts() }
                }
            }
        } else if tokenError {
            ContentUnavailableView(
                "Purchase unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Could not attach your account to this purchase. Sign in again and retry.")
            )
        } else if hasSession == false {
            ContentUnavailableView(
                "Sign in required",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in to purchase a plan so your subscription can be linked to your account.")
            )
        } else if hasSession == true,
                  let token = appAccountToken,
                  store.loadState == .loaded,
                  store.hasCompleteCurrentPlatformCatalog {
            let presentation = SubscriptionPaywallPresentation(
                isPaidActive: isPaidActive
            )
            subscriptionStore(presentation: presentation, token: token)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func subscriptionStore(
        presentation: SubscriptionPaywallPresentation,
        token: UUID
    ) -> some View {
        // Do not use the subscription-group initializer here: the App Store
        // group contains both iOS and macOS products. The explicit catalog is
        // platform-scoped, so an iPhone never sees macOS upgrade options.
        configuredSubscriptionStore(
            SubscriptionStoreView(
                productIDs: RishiProductID.paywallProductIDs(
                    activeProductID: activeProductID
                )
            ) {
                marketingContent(presentation: presentation)
            },
            token: token
        )
    }

    @ViewBuilder
    private func marketingContent(
        presentation: SubscriptionPaywallPresentation
    ) -> some View {
        VStack {
            Image("rishi")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .clipShape(.rect(cornerRadius: 20))
            Text("Rishi Reader")
                .fontWeight(.semibold)
                .font(.largeTitle)
            VStack(spacing: 10) {
                Text("Bring every book to life")
                    .font(.headline)
                    .foregroundStyle(RishiColor.accent)
                Text(
                    "Listen to books with natural voices, ask questions as you read, and pick up where you left off on any device"
                )
            }
            .padding(10)
            .multilineTextAlignment(.center)

            if presentation.action == .manage {
                VStack(spacing: 8) {
                    Label("Your current plan is active", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(RishiColor.accent)
                    Text("Choose an upgrade below if you want more narration or voice chat.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
            }

            // Active subscribers are restored automatically from
            // Transaction.currentEntitlements. Keep the explicit sync
            // fallback visible for users who are not yet recognized as paid.
            if presentation.showsRestorePurchases {
                Button("Restore Purchases") {
                    Task { await restorePurchases() }
                }
                .disabled(isRestoring)
                .accessibilityHint("Checks your Apple ID for active Rishi subscriptions")
                if isRestoring {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func configuredSubscriptionStore<Content: View>(
        _ subscriptionStore: Content,
        token: UUID
    ) -> some View {
        subscriptionStore
            .inAppPurchaseOptions { _ in
                [.appAccountToken(token)]
            }
            .onInAppPurchaseStart { _ in
                if (try? await KeychainSessionStore().load()) == nil {
                    await MainActor.run { tokenError = true }
                }
            }
            .onInAppPurchaseCompletion { _, result in
                await handlePurchaseCompletion(result)
            }
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStorePickerItemBackground(.thinMaterial)
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/privacy")!,
                for: .privacyPolicy
            )
            .subscriptionStorePolicyDestination(
                url: URL(string: "https://rishi.fidexa.org/terms")!,
                for: .termsOfService
            )
            .tint(RishiColor.accent)
            .id(store.retryID)
            .alert("Restore Purchases", isPresented: Binding(
                get: { restoreMessage != nil },
                set: { if !$0 { restoreMessage = nil } }
            )) {
                Button("OK", role: .cancel) { restoreMessage = nil }
            } message: {
                Text(restoreMessage ?? "")
            }
    }

    private func handlePurchaseCompletion(
        _ result: Result<Product.PurchaseResult, any Error>
    ) async {
        guard let purchaseResult = try? result.get(),
              case .success(.verified) = purchaseResult
        else {
            return
        }

        await MainActor.run {
            onPurchaseCompleted()
        }

        await store.process(purchaseResult: purchaseResult)
        if let entitlementRefreshCoordinator {
            await entitlementRefreshCoordinator.refreshIfSignedIn(
                reason: .foreground
            )
        }
        await onPurchaseProcessed()
    }

    private func restorePurchases() async {
        guard let restoreService, let entitlementRefreshCoordinator else {
            restoreMessage = "Restore is unavailable until you are signed in."
            return
        }

        isRestoring = true
        defer { isRestoring = false }
        do {
            let outcome = try await restoreService.restore()
            await entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground)
            restoreMessage = RestoreMessage.forOutcome(outcome)
        } catch let error as RestoreError {
            Log.event("iap.restore.user_facing_failure", level: .warning)
            restoreMessage = RestoreMessage.forError(error)
        } catch {
            Log.event(
                "iap.restore.unexpected_failure",
                level: .warning,
                data: ["error": String(describing: error)]
            )
            restoreMessage = "We couldn’t verify your purchases right now. Check your Apple ID connection and try again."
        }
    }
}

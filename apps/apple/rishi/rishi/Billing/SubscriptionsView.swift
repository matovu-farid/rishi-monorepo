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
    public let customerEntitlements: CustomerEntitlements
    public let store: Store

    public init(
        groupID: GroupId?,
        entitlementRefreshCoordinator: EntitlementRefreshCoordinator,
        restoreService: RestoreService,
        customerEntitlements: CustomerEntitlements,
        store: Store
    ) {
        self.groupID = groupID
        self.entitlementRefreshCoordinator = entitlementRefreshCoordinator
        self.restoreService = restoreService
        self.customerEntitlements = customerEntitlements
        self.store = store
    }
}

public struct SubscriptionsView: View {
    private static let macPaywallContentWidth: CGFloat = 560

    private var store: Store { dependencies.store }
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementSnapshotStore.self) private var entitlementStore
    private let dependencies: SubscriptionDependencies
    private let credentialAuthority: SessionCredentialAuthority
    private let credentialSnapshot: CredentialSnapshot
    private var customerEntitlements: CustomerEntitlements { dependencies.customerEntitlements }
    @State private var hasSession: Bool?
    @State private var tokenError = false
    @State private var isRestoring = false
    @State private var isVisible = false
    @State private var restoreAttempt: UUID?
    @State private var restoreMessage: String?
    /// Preloaded `appAccountToken` — only non-nil after a confirmed session.
    /// Used so `.inAppPurchaseOptions` never returns `[]` (which would allow
    /// a purchase without account binding; that API is non-throwing).
    @State private var appAccountToken: UUID?
    @State private var purchaseCredentialLease: CredentialLease?

    private let onPurchaseCompleted: () -> Void
    private let onPurchaseProcessed: @MainActor () async -> Void

    private var isPaidActive: Bool {
        let serverPaid = entitlementStore.resolvedSnapshot?.isPaidActive == true
        let storeKitPaid = groupID.map {
            customerEntitlements.hasActiveSubscription(in: $0.value)
        } ?? false
        return SubscriptionManagementPolicy.isSubscribed(serverPaidActive: serverPaid, deviceSubscriptionActive: storeKitPaid)
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

    init(
        dependencies: SubscriptionDependencies,
        credentialAuthority: SessionCredentialAuthority,
        credentialSnapshot: CredentialSnapshot,
        onPurchaseCompleted: @escaping () -> Void = {},
        onPurchaseProcessed: @escaping @MainActor () async -> Void = {}
    ) {
        self.dependencies = dependencies
        self.credentialAuthority = credentialAuthority
        self.credentialSnapshot = credentialSnapshot
        self.onPurchaseCompleted = onPurchaseCompleted
        self.onPurchaseProcessed = onPurchaseProcessed
    }

    private var groupID: GroupId? {
        dependencies.groupID
    }

    private var entitlementRefreshCoordinator: EntitlementRefreshCoordinator? {
        dependencies.entitlementRefreshCoordinator
    }

    private var restoreService: RestoreService? {
        dependencies.restoreService
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                RishiColor.accent
                    .opacity(0.1)
                    .ignoresSafeArea()
                content
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; restoreAttempt = nil; isRestoring = false }
            .task {
                do {
                    _ = try AppAccountToken.currentPurchaseOptions(snapshot: credentialSnapshot, authority: credentialAuthority)
                    appAccountToken = AppAccountToken.derive(userId: credentialSnapshot.lease.rawUserID)
                    purchaseCredentialLease = credentialSnapshot.lease
                    hasSession = true
                } catch {
                    hasSession = false
                    appAccountToken = nil
                    purchaseCredentialLease = nil
                    tokenError = true
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .padding(.leading, 12)
                .accessibilityLabel("Close subscriptions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                #if targetEnvironment(macCatalyst)
                .frame(maxWidth: Self.macPaywallContentWidth)
                #endif
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
        #if targetEnvironment(macCatalyst)
        .frame(maxWidth: Self.macPaywallContentWidth)
        #endif
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
                // This callback cannot veto StoreKit. Options stay bound to
                // the presented owner; only its admitted completion may publish.
                guard let purchaseCredentialLease, credentialAuthority.isCurrent(purchaseCredentialLease) else {
                    await MainActor.run { tokenError = true }
                    return
                }
            }
            .onInAppPurchaseCompletion { _, result in
                await handlePurchaseCompletion(result)
            }
            #if targetEnvironment(macCatalyst)
            // Keep one actionable button per plan and let StoreKit choose its
            // supported Catalyst placement for the full-window presentation.
            .subscriptionStoreControlStyle(.buttons)
            .subscriptionStoreButtonLabel(.multiline)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            .subscriptionStoreButtonLabel(.multiline)
            #endif
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
              case .success(.verified(let transaction)) = purchaseResult,
              let lease = purchaseCredentialLease,
              transaction.appAccountToken == AppAccountToken.derive(userId: lease.rawUserID),
              credentialAuthority.isCurrent(lease) else { return }
        _ = credentialAuthority.performIfCurrent(lease) { onPurchaseCompleted() }
        await dependencies.store.process(purchaseResult: purchaseResult, credentialContext: .normal(lease))
        guard credentialAuthority.isCurrent(lease) else { return }
        _ = await dependencies.entitlementRefreshCoordinator.refreshIfSignedIn(reason: .foreground,
            credentialContext: .normal(lease))
        guard credentialAuthority.isCurrent(lease) else { return }
        await onPurchaseProcessed()
    }

    private func restorePurchases() async {
        let lease = credentialSnapshot.lease
        guard credentialAuthority.isCurrent(lease), isVisible, !isRestoring else { return }
        let attempt = UUID()
        restoreAttempt = attempt
        isRestoring = true
        defer {
            if restoreAttempt == attempt { isRestoring = false; restoreAttempt = nil }
        }
        do {
            let outcome = try await restoreAndRefresh(restoreService: dependencies.restoreService,
                refreshCoordinator: dependencies.entitlementRefreshCoordinator, credentialContext: .normal(lease))
            guard isVisible, restoreAttempt == attempt, !Task.isCancelled else { return }
            _ = credentialAuthority.performIfCurrent(lease) { restoreMessage = RestoreMessage.forOutcome(outcome) }
        } catch {
            let originalError = error
            guard credentialAuthority.isCurrent(lease), isVisible,
                  restoreAttempt == attempt, !Task.isCancelled else { return }
            Log.error("iap.restore.user_facing_failure", error: originalError)
            _ = credentialAuthority.performIfCurrent(lease) {
                if let restoreError = originalError as? RestoreError { restoreMessage = RestoreMessage.forError(restoreError) }
                else { restoreMessage = "We couldn’t verify your purchases right now. Check your Apple ID connection and try again." }
            }
        }
    }

}

extension View {
    @ViewBuilder
    func rishiSubscriptionPresentation<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    @ViewBuilder
    func rishiSubscriptionPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}

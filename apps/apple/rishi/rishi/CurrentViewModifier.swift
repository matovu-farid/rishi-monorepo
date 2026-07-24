


import OSLog
import StoreKit
import SwiftUI
import RishiBilling
import RishiCore


// MARK: - Customer Entitlements

// A view modifier that checks the customer's current entitlements.
//
// Only use once in your app.
@available(iOS 18.4, *)
private struct CustomerEntitlementsViewModifier: ViewModifier {
    private let logger = Logger(subsystem: "Rishi", category: "CustomerEntitlementsViewModifier")
   
    @Environment(\.services) private var services
    @Environment(SubscriptionService.self) private var subscriptionService
    

    private var customerEntitlements = CustomerEntitlements.shared

//    @State private var rishiProStatus: RishiProStatus?

    func body(content: Content) -> some View {
        content
            // Check the customer's current entitlements.
            .task { await checkCurrentUserState() }
            // Observe changes to the customer's entitlements.
            .task { observeEntitlementUpdates() }
            // Observe updates to the user's status for SKDemo+.
            .onChange(of: customerEntitlements.subscriptionStatuses) { _, subscriptionStatuses in
                do {
                    if  let groupID = services?.groupID{
                        let subscriptionStatuses = subscriptionStatuses[groupID.value]
                        let highestSubcription = try subscriptionStatuses?.activeSubscriptionStatuses.highestSubscriptionStatus
                        
                        if let highestSubcription {
                            
                            subscriptionService.saveSubscription(subscription: highestSubcription)
                            // Entitlement-sync may have just landed; refresh
                            // so Settings/gates update without waiting for
                            // the next foreground.
                            if let coordinator = services?.entitlementRefreshCoordinator {
                                Task {
                                    await coordinator.refreshIfSignedIn(reason: .foreground)
                                }
                            }
                        }
                    }
                } catch {
                    logger.error("""
                    Fail to transform statuses for subscription group ID \(error)
                    """)
                    return
                }
            }
  
         
    }

    private func checkCurrentUserState() async {
        // Check if there are any unfinished transactions.
        await CustomerEntitlements.shared.checkForUnfinishedTransactions()
        // Check if there are any current entitlements.
        await CustomerEntitlements.shared.checkForCurrentEntitlements()
        // Check current status.
        await CustomerEntitlements.shared.checkCurrentStatuses()
    }

    private func observeEntitlementUpdates() {
        // Begin observing StoreKit transaction updates in case a
        // transaction happens on another device.
        CustomerEntitlements.shared.observeTransactionUpdates()
        // Begin observing StoreKit status updates.
        CustomerEntitlements.shared.observeStatusUpdates()
    }

    private func transformStatus(_ subscriptionStatuses: [SubscriptionStatus]?) throws ->  EntitlementLevel? {
        try subscriptionStatuses?.activeSubscriptionStatuses.highestSubscriptionStatus.flatMap { EntitlementLevel.from(subscription: $0)}
    }
}

@available(iOS 18.4, *)
extension View {
    func checkCustomerEntitlements() -> some View {
        modifier(CustomerEntitlementsViewModifier())
    }
}

extension EnvironmentValues {
    // Make globally accessible the user's status for SKDemo+ to always have the latest information
    // readily available.
    @Entry fileprivate(set) var rishiProStatus: EntitlementLevel = .unsubscribed
    // Make globally accessible the user's owned cars to always have the latest information
    // readily available.
}

// MARK: - Store

// A view modifier that requests products from the App Store.
//
// Only use this once in your app.
@available(iOS 18.4, *)
private struct ProductLoaderViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .task {
                await Store.shared.loadProducts()
            }
    }
}

@available(iOS 18.4, *)
extension View {
    func loadProducts() -> some View {
        modifier(ProductLoaderViewModifier())
    }
}

// MARK: - Errors

// A view modifier that listens for errors encountered during purchases and entitlement checks.
//
// This only use once in your app.
@available(iOS 18.4, *)
private struct ErrorObserverViewModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    private var customerEntitlements = CustomerEntitlements.shared
    private var store = Store.shared

    @State private var error: (any Error)?

    private var showErrorAlert: Binding<Bool> {
        Binding {
            error != nil
        } set: {
            guard !$0 else { return }
            error = nil
        }
    }

    @ViewBuilder
    private var errorAlertActionView: some View {
        Button("Restore Purchases", role: .destructive) {
            Task {
                do {
                    try await AppStore.sync()
                } catch {
                    self.error = error
                }
            }
        }
        Button("OK", role: .cancel) {
            dismiss()
        }
    }

    private var errorAlertMessageView: some View {
        Text(verbatim: "Contact the developer for more information.")
    }

    func body(content: Content) -> some View {
        content
            // Observe errors encountered while checking customer entitlements.
            .onChange(of: customerEntitlements.error) { _, error in
                switch error {
                case .some(.invalidTransaction), .some(.entitlementSyncFailed):
                    self.error = error
                case _:
                    return
                }
            }
            // Observe errors encountered during purchases.
            .onChange(of: store.error) { _, error in
                switch error {
                case .some(.invalidTransaction):
                    self.error = error
                case _:
                    return
                }
            }
            .alert(
                "An error occurred while checking your purchase history.",
                isPresented: showErrorAlert,
                actions: { errorAlertActionView },
                message: { errorAlertMessageView }
            )
    }
}

@available(iOS 18.4, *)
 extension View {
    func observeErrors() -> some View {
        modifier(ErrorObserverViewModifier())
    }
}

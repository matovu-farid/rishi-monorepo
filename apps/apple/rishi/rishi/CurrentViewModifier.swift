


import Foundation
import Observation
import OSLog
import StoreKit
import SwiftUI




// MARK: - Store

// A view modifier that requests products from the App Store.
//
// Only use this once in your app.
@available(iOS 18.4, *)
private struct ProductLoaderViewModifier: ViewModifier {
    @Environment(Store.self) private var store
    func body(content: Content) -> some View {
        content
            .task {
                await store.loadProducts()
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

@MainActor
@Observable
final class ErrorObserverPresentationState {
    var error: (any Error)?
    private(set) var activeRestoreCount = 0

    private var lastHandledCustomerError: CustomerEntitlementsError?
    private var lastHandledStoreError: StoreError?
    private var didInitializeHandledErrors = false

    func initializeHandledErrors(
        customerError: CustomerEntitlementsError?,
        storeError: StoreError?
    ) {
        guard !didInitializeHandledErrors else { return }
        didInitializeHandledErrors = true
        lastHandledCustomerError = customerError
        lastHandledStoreError = storeError
    }

    func recordHandledCustomerError(_ customerError: CustomerEntitlementsError?) {
        lastHandledCustomerError = customerError
        if Self.isEligible(customerError) {
            error = customerError
        }
    }

    func recordHandledStoreError(_ storeError: StoreError?) {
        lastHandledStoreError = storeError
        if storeError == .invalidTransaction {
            error = storeError
        }
    }

    func beginRestore() {
        activeRestoreCount += 1
    }

    func endRestore() {
        guard activeRestoreCount > 0 else { return }
        activeRestoreCount -= 1
    }

    func isBlocking(
        customerError: CustomerEntitlementsError?,
        storeError: StoreError?
    ) -> Bool {
        error != nil
            || activeRestoreCount > 0
            || (Self.isEligible(customerError) && customerError != lastHandledCustomerError)
            || (storeError == .invalidTransaction && storeError != lastHandledStoreError)
    }

    private static func isEligible(_ error: CustomerEntitlementsError?) -> Bool {
        switch error {
        case .some(.invalidTransaction), .some(.entitlementSyncFailed):
            true
        case .none, .some(.failedToFetchPersistedData), .some(.failedToUpdatePersistedData):
            false
        }
    }
}

typealias ErrorPresentationObservation = @MainActor (
    _ source: ErrorObserverPresentationState,
    _ isRegistered: Bool,
    _ liveBlocking: @escaping @MainActor () -> Bool
) -> Void

// A view modifier that listens for errors encountered during purchases and entitlement checks.
//
// This only use once in your app.
@available(iOS 18.4, *)
private struct ErrorObserverViewModifier: ViewModifier {
    private let observation: ErrorPresentationObservation?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services

    @Environment(CustomerEntitlements.self) private var customerEntitlements
    @Environment(Store.self) private var store
    @Environment(\.appDependencies) private var dependencies

    @State private var presentationState = ErrorObserverPresentationState()
    @State private var isVisible = false
    @State private var restoreAttempt: UUID?

    init(observation: ErrorPresentationObservation? = nil) {
        self.observation = observation
    }

    private enum RestorePresentationError: LocalizedError {
        case restored
        case nothingToRestore
        case failed(any Error)

        var errorDescription: String? {
            switch self {
            case .restored:
                return "Purchases restored."
            case .nothingToRestore:
                return "No purchases were found to restore."
            case .failed(let error):
                return "Could not restore purchases: \(error.localizedDescription)"
            }
        }
    }

    private var showErrorAlert: Binding<Bool> {
        Binding {
            presentationState.error != nil
        } set: {
            guard !$0 else { return }
            presentationState.error = nil
            reportObservation(isRegistered: true)
        }
    }

    @ViewBuilder
    private var errorAlertActionView: some View {
        Button("Restore Purchases", role: .destructive) {
            guard isVisible, let authority = dependencies?.credentialAuthority,
                  let snapshot = try? authority.snapshot() else { return }
            let lease = snapshot.lease
            let attempt = UUID()
            restoreAttempt = attempt
            presentationState.beginRestore()
            reportObservation(isRegistered: true)
            Task {
                defer {
                    presentationState.endRestore()
                    if restoreAttempt == attempt { restoreAttempt = nil }
                    reportObservation(isRegistered: isVisible)
                }
                do {
                    guard let services else {
                        presentationState.error = RestorePresentationError.failed(
                            NSError(domain: "RishiBilling", code: 1)
                        )
                        reportObservation(isRegistered: true)
                        return
                    }
                    let outcome = try await restoreAndRefresh(restoreService: services.billing.restoreService,
                        refreshCoordinator: services.billing.entitlementRefreshCoordinator, credentialContext: .normal(lease))
                    guard authority.isCurrent(lease), isVisible,
                          restoreAttempt == attempt, !Task.isCancelled else { return }
                    switch outcome {
                    case .restored:
                        presentationState.error = RestorePresentationError.restored
                    case .nothingToRestore:
                        presentationState.error = RestorePresentationError.nothingToRestore
                    }
                    reportObservation(isRegistered: true)
                } catch {
                    let restoreError = error
                    guard authority.isCurrent(lease), isVisible,
                          restoreAttempt == attempt, !Task.isCancelled else { return }
                    presentationState.error = RestorePresentationError.failed(restoreError)
                    reportObservation(isRegistered: true)
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
            .onAppear {
                isVisible = true
                presentationState.initializeHandledErrors(
                    customerError: customerEntitlements.error,
                    storeError: store.error
                )
                reportObservation(isRegistered: true)
            }
            .onDisappear {
                isVisible = false
                restoreAttempt = nil
                reportObservation(isRegistered: false)
            }
            // Observe errors encountered while checking customer entitlements.
            .onChange(of: customerEntitlements.error) { _, error in
                presentationState.recordHandledCustomerError(error)
                reportObservation(isRegistered: true)
            }
            // Observe errors encountered during purchases.
            .onChange(of: store.error) { _, error in
                presentationState.recordHandledStoreError(error)
                reportObservation(isRegistered: true)
            }
            .alert(
                "An error occurred while checking your purchase history.",
                isPresented: showErrorAlert,
                actions: { errorAlertActionView },
                message: { errorAlertMessageView }
            )
    }

    private func reportObservation(isRegistered: Bool) {
        guard let observation else { return }
        observation(presentationState, isRegistered) { @MainActor in
            presentationState.isBlocking(
                customerError: customerEntitlements.error,
                storeError: store.error
            )
        }
    }
}

@available(iOS 18.4, *)
 extension View {
    func observeErrors(
        observation: ErrorPresentationObservation? = nil
    ) -> some View {
        modifier(ErrorObserverViewModifier(observation: observation))
    }
}

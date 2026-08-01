

import SwiftUI
import Observation

@MainActor
@Observable
final class MacAccountMenuModel {

    enum SubscriptionAction: Equatable {
        case subscribe
        case manage
        case unavailable
    }


    struct Payload {
        var userEmail: String?
        var subscriptionAction: SubscriptionAction = .unavailable
        var onSubscribe: () -> Void = {}
        var onManageSubscription: () -> Void
        var onAppleManageSubscription: () -> Void = {}
        var onSignOut: () -> Void
        var onDeleteAccount: () -> Void = {}
        var onOpenPrivacy: () -> Void
        var onOpenTerms: () -> Void
    }

    private(set) var payload: Payload?
    var deleteConfirmationPresented = false
    var deleteError: String?
    var onDeleteConfirmed: () async throws -> Void = {}


    nonisolated init() {}

    func update(_ payload: Payload) { self.payload = payload }
    func clear() { self.payload = nil }

    func requestDelete() {
        deleteError = nil
        deleteConfirmationPresented = true
    }

    func confirmDelete() async {
        do {
            try await onDeleteConfirmed()
            deleteConfirmationPresented = false
        } catch {
            deleteError = "We couldn't delete your account. Check your connection and try again."
        }
    }
}

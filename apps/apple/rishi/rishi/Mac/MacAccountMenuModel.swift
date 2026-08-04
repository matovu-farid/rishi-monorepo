

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
        var userUsername: String? = nil
        var subscriptionAction: SubscriptionAction = .unavailable
        var onSubscribe: () -> Void = {}
        var onManageSubscription: () -> Void
        var onAppleManageSubscription: () -> Void = {}
        var onSignOut: () -> Void
        var onDeleteAccount: () -> Void = {}
        var onEditUsername: () -> Void = {}
        var onOpenPrivacy: () -> Void
        var onOpenTerms: () -> Void

        init(
            userEmail: String?,
            userUsername: String? = nil,
            subscriptionAction: SubscriptionAction = .unavailable,
            onSubscribe: @escaping () -> Void = {},
            onManageSubscription: @escaping () -> Void,
            onAppleManageSubscription: @escaping () -> Void = {},
            onSignOut: @escaping () -> Void,
            onDeleteAccount: @escaping () -> Void = {},
            onEditUsername: @escaping () -> Void = {},
            onOpenPrivacy: @escaping () -> Void,
            onOpenTerms: @escaping () -> Void
        ) {
            self.userEmail = userEmail
            self.userUsername = userUsername
            self.subscriptionAction = subscriptionAction
            self.onSubscribe = onSubscribe
            self.onManageSubscription = onManageSubscription
            self.onAppleManageSubscription = onAppleManageSubscription
            self.onSignOut = onSignOut
            self.onDeleteAccount = onDeleteAccount
            self.onEditUsername = onEditUsername
            self.onOpenPrivacy = onOpenPrivacy
            self.onOpenTerms = onOpenTerms
        }
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

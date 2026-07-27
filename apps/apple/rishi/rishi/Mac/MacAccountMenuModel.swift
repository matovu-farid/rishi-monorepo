

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
        var onSignOut: () -> Void
        var onOpenPrivacy: () -> Void
        var onOpenTerms: () -> Void
    }

    private(set) var payload: Payload?


    nonisolated init() {}

    func update(_ payload: Payload) { self.payload = payload }
    func clear() { self.payload = nil }
}



import SwiftUI
import Observation

@MainActor
@Observable
final class MacAccountMenuModel {


    struct Payload {
        var userEmail: String?
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

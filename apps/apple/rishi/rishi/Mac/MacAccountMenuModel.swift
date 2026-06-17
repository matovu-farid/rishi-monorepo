//
//  MacAccountMenuModel.swift
//  rishi
//
//  App-level (focus-independent) source for the Mac menu-bar Account submenu.
//  The Account/legal/auth payload is app-global, so unlike the scene-scoped
//  reader prefs it must NOT ride `focusedSceneValue` (which resolves to nil
//  when the menu bar opens / focus leaves the content view — the cause of the
//  greyed-out "Not signed in" submenu bug). Held on `AppDependencies` like
//  `MacCommandRouter` so `WindowGroup.commands { ... }` reads the same live
//  instance regardless of which window/sheet has focus.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class MacAccountMenuModel {

    /// The resolved signed-in account payload. `nil` when signed out (or before
    /// the signed-in view mounts), which disables the submenu commands for free.
    struct Payload {
        var userEmail: String?
        var onManageSubscription: () -> Void
        var onSignOut: () -> Void
        var onOpenPrivacy: () -> Void
        var onOpenTerms: () -> Void
    }

    private(set) var payload: Payload?

    /// `nonisolated` so `AppDependencies.init()` (nonisolated) can hold this as
    /// a `let`. Mirrors `MacCommandRouter.init`.
    nonisolated init() {}

    func update(_ payload: Payload) { self.payload = payload }
    func clear() { self.payload = nil }
}

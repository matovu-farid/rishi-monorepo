//
//  MacAccountMenuModelTests.swift
//  rishiTests
//
//  Regression test for the greyed-out "Not signed in" Account submenu bug.
//  The account/legal/auth payload is app-GLOBAL, so it must live on an
//  app-level @Observable (focus-independent) rather than the scene-scoped
//  `focusedSceneValue` (which resolves to nil when the menu bar opens). These
//  tests pin that the account state is reachable app-level: present + populated
//  when signed in (menu enabled, real email shown), nil when signed out
//  (menu disabled).
//

import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("MacAccountMenuModel app-level account state")
struct MacAccountMenuModelTests {

    /// A fresh model is signed-out: `payload == nil` so the submenu commands
    /// disable themselves (the `.disabled(payload == nil)` path is true) and
    /// the email line falls back to "Not signed in".
    @Test("Fresh model has no payload (signed-out disables the submenu)")
    func freshModelHasNoPayload() {
        let model = MacAccountMenuModel()
        #expect(model.payload == nil)
    }

    /// After `update`, the payload is present AND carries the real signed-in
    /// email — NOT the "Not signed in" literal — which proves the menu would
    /// render the address and enable its commands regardless of scene focus.
    @Test("update publishes the real account payload (menu enabled, real email)")
    func updatePublishesPayload() {
        let model = MacAccountMenuModel()
        model.update(
            MacAccountMenuModel.Payload(
                userEmail: "a@b.com",
                onManageSubscription: {},
                onSignOut: {},
                onOpenPrivacy: {},
                onOpenTerms: {}
            )
        )
        #expect(model.payload != nil)
        #expect(model.payload?.userEmail == "a@b.com")
        // The email is the real address, not the disabled fallback — proves the
        // `.disabled(payload == nil)` guard is false (commands are enabled).
        #expect(model.payload?.userEmail != "Not signed in")
    }

    /// After `clear` (sign-out), the payload is nil again so the submenu
    /// disables every command.
    @Test("clear removes the payload (sign-out disables the submenu)")
    func clearRemovesPayload() {
        let model = MacAccountMenuModel()
        model.update(
            MacAccountMenuModel.Payload(
                userEmail: "a@b.com",
                onManageSubscription: {},
                onSignOut: {},
                onOpenPrivacy: {},
                onOpenTerms: {}
            )
        )
        #expect(model.payload != nil)
        model.clear()
        #expect(model.payload == nil)
    }

    /// Each action closure routes to its own action — proving the menu buttons
    /// fire the correct flow no matter which window/sheet holds focus.
    @Test("payload action closures each fire their own action")
    func payloadClosuresFire() {
        var manageFired = false
        var signOutFired = false
        var privacyFired = false
        var termsFired = false

        let model = MacAccountMenuModel()
        model.update(
            MacAccountMenuModel.Payload(
                userEmail: "a@b.com",
                onManageSubscription: { manageFired = true },
                onSignOut: { signOutFired = true },
                onOpenPrivacy: { privacyFired = true },
                onOpenTerms: { termsFired = true }
            )
        )

        model.payload?.onManageSubscription()
        model.payload?.onSignOut()
        model.payload?.onOpenPrivacy()
        model.payload?.onOpenTerms()

        #expect(manageFired)
        #expect(signOutFired)
        #expect(privacyFired)
        #expect(termsFired)
    }
}

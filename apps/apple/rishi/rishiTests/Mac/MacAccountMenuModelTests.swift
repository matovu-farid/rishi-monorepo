












import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("MacAccountMenuModel app-level account state")
struct MacAccountMenuModelTests {

    
    
    
    @Test("Fresh model has no payload (signed-out disables the submenu)")
    func freshModelHasNoPayload() {
        let model = MacAccountMenuModel()
        #expect(model.payload == nil)
    }

    
    
    
    @Test("update publishes the real account payload (menu enabled, real email)")
    func updatePublishesPayload() {
        let model = MacAccountMenuModel()
        model.update(
            MacAccountMenuModel.Payload(
                userEmail: "a@b.com",
                userUsername: "reader_one",
                onManageSubscription: {},
                onSignOut: {},
                onOpenPrivacy: {},
                onOpenTerms: {}
            )
        )
        #expect(model.payload != nil)
        #expect(model.payload?.userEmail == "a@b.com")
        #expect(model.payload?.userUsername == "reader_one")
        
        
        #expect(model.payload?.userEmail != "Not signed in")
    }

    @Test("payload routes username editing")
    func payloadUsernameEditFires() {
        var editFired = false
        let model = MacAccountMenuModel()
        model.update(
            MacAccountMenuModel.Payload(
                userEmail: "a@b.com",
                userUsername: "reader_one",
                onManageSubscription: {},
                onSignOut: {},
                onEditUsername: { editFired = true },
                onOpenPrivacy: {},
                onOpenTerms: {}
            )
        )

        model.payload?.onEditUsername()

        #expect(editFired)
    }

    
    
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

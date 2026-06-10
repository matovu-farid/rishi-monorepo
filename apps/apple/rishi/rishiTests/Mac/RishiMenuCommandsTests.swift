//
//  RishiMenuCommandsTests.swift
//  rishiTests
//
//  Phase 12 Plan 12-01 — covers the SwiftUI `Commands` builder wiring.
//  SwiftUI does not expose a way to programmatically invoke a menu item
//  without running a UIApplication / NSApplication, so these tests are
//  intentionally narrow: they prove the body builds and the router is held
//  by reference (so menu taps later in the run loop will land on the same
//  instance that `RootView` is observing). The actual ⌘O / ⌘F intent
//  routing is exercised by `MacCommandRouterTests`.
//

import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("RishiMenuCommands wiring")
struct RishiMenuCommandsTests {

    @Test("Commands body builds without crashing")
    func commandsBodyBuilds() {
        let router = MacCommandRouter()
        let commands = RishiMenuCommands(router: router)
        _ = commands.body  // touch the property to force the result builder
        #expect(router.pendingIntent == nil)
    }

    @Test("Router is held by reference (menu taps reach the same instance)")
    func routerHeldByReference() {
        let router = MacCommandRouter()
        let commands = RishiMenuCommands(router: router)
        // Mutating the router via its public API must be visible to anything
        // that captured it (the menu builder retains it as a stored property).
        router.send(.focusSearch)
        #expect(commands.router.pendingIntent == .focusSearch)
        commands.router.consume()
        #expect(router.pendingIntent == nil)
    }
}

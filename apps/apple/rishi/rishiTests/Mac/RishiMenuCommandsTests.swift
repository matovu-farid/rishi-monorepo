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
        let commands = RishiMenuCommands(router: router, account: MacAccountMenuModel())
        _ = commands.body  // touch the property to force the result builder
        #expect(router.pendingIntent == nil)
    }

    @Test("Router is held by reference (menu taps reach the same instance)")
    func routerHeldByReference() {
        let router = MacCommandRouter()
        let commands = RishiMenuCommands(router: router, account: MacAccountMenuModel())
        // Mutating the router via its public API must be visible to anything
        // that captured it (the menu builder retains it as a stored property).
        router.send(.focusSearch)
        #expect(commands.router.pendingIntent == .focusSearch)
        commands.router.consume()
        #expect(router.pendingIntent == nil)
    }

    // BUG REPRO (Mac import refuses): macOS auto-adds a system "Open…" command
    // bound to ⌘O for any app that declares document types (CFBundleDocumentTypes).
    // Binding our own "Import Book…" command to the SAME ⌘O makes UIKit drop /
    // merge one of the two — it logs `_UIMenuBuilderError ... undefined behavior`
    // — and the survivor is the system Open, which dead-ends in an NSOpenPanel
    // with no backing NSDocument. The user's File menu then offers only a
    // non-functional "Open…", so the in-app document picker is never reached
    // (the runtime log shows NSOpenPanel, never UIDocumentPickerViewController).
    // Import must therefore avoid the system-reserved ⌘O chord.
    @Test("Import Book shortcut avoids the system-reserved File > Open (Cmd+O)")
    func importShortcutAvoidsSystemOpenCollision() {
        let shortcut = RishiKeyboardShortcut.importBook
        let collidesWithSystemOpen =
            shortcut.key.character == "o" && shortcut.modifiers == .command
        #expect(
            collidesWithSystemOpen == false,
            "Import Book must not use ⌘O — it collides with the system File > Open command on Mac"
        )
        // Lock the chosen replacement chord (⌘I = Import).
        #expect(shortcut.key.character == "i")
        #expect(shortcut.modifiers == .command)
    }

    // Phase 32 Plan 32-04 — the custom `CommandMenu("View")` was merged into
    // the system View menu via `CommandGroup(after: .sidebar)` so exactly one
    // "View" menu appears on Mac. The "exactly one View menu" rendering is a
    // MANUAL MAC SMOKE (SwiftUI menu structure isn't unit-introspectable
    // without a running NS/UIApplication) — see the plan's verification note.
    // What we CAN pin here: the View-menu intents still round-trip through the
    // same MacCommandRouter the (now relocated) buttons send to, so the menu
    // relocation didn't change any button body, intent, or routing.
    @Test("View-menu intents still round-trip through MacCommandRouter")
    func viewMenuIntentsRoundTrip() {
        let router = MacCommandRouter()

        router.send(.selectTheme(.dark))
        #expect(router.pendingIntent == .selectTheme(.dark))
        router.consume()

        router.send(.fontIncrease)
        #expect(router.pendingIntent == .fontIncrease)
        router.consume()

        router.send(.selectTab(.chats))
        #expect(router.pendingIntent == .selectTab(.chats))
        router.consume()

        #expect(router.pendingIntent == nil)
    }
}

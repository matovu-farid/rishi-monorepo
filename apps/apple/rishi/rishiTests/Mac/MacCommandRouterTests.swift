//
//  MacCommandRouterTests.swift
//  rishiTests
//
//  Phase 12 Plan 12-01 — covers the Mac Catalyst command router and the
//  centralised keyboard-shortcut table. Swift Testing only (no XCTest).
//

import Testing
import SwiftUI
@testable import rishi

@MainActor
@Suite("MacCommandRouter + RishiKeyboardShortcut")
struct MacCommandRouterTests {

    @Test("Router starts empty")
    func startsEmpty() {
        let r = MacCommandRouter()
        #expect(r.pendingIntent == nil)
    }

    @Test("send sets pendingIntent; consume clears it")
    func sendThenConsume() {
        let r = MacCommandRouter()
        r.send(.importBook)
        #expect(r.pendingIntent == .importBook)
        r.consume()
        #expect(r.pendingIntent == nil)
    }

    @Test("Last send wins (coalesce semantics)")
    func lastSendWins() {
        let r = MacCommandRouter()
        r.send(.fontIncrease)
        r.send(.fontDecrease)
        #expect(r.pendingIntent == .fontDecrease)
    }

    @Test("Shortcut key + modifier table")
    func shortcutTable() {
        #expect(RishiKeyboardShortcut.importBook.key   == "i")
        #expect(RishiKeyboardShortcut.find.key         == "f")
        #expect(RishiKeyboardShortcut.addBookmark.key  == "d")
        #expect(RishiKeyboardShortcut.fontIncrease.key == "+")
        #expect(RishiKeyboardShortcut.fontDecrease.key == "-")
        #expect(RishiKeyboardShortcut.libraryTab.key   == "1")
        #expect(RishiKeyboardShortcut.chatsTab.key     == "2")

        for s: RishiKeyboardShortcut in [.importBook, .find, .addBookmark,
                                         .fontIncrease, .fontDecrease,
                                         .libraryTab, .chatsTab] {
            #expect(s.modifiers == .command)
        }
    }

    // Phase 37 Plan 37-06 — ⌘D add-bookmark. The shortcut binds to ⌘D and the
    // `.addBookmark` intent round-trips through the router like every other
    // menu command (the router-to-notification dispatch lives in
    // MacCommandDispatchModifier and is hardware-verified).
    @Test("addBookmark shortcut is ⌘D and the intent round-trips through the router")
    func addBookmarkShortcutAndIntent() {
        #expect(RishiKeyboardShortcut.addBookmark.key == "d")
        #expect(RishiKeyboardShortcut.addBookmark.modifiers == .command)

        let r = MacCommandRouter()
        r.send(.addBookmark)
        #expect(r.pendingIntent == .addBookmark)
        r.consume()
        #expect(r.pendingIntent == nil)
    }
}

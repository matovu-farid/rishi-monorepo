//
//  RishiMenuCommands.swift
//  rishi
//
//  Phase 12 Plan 12-01 — Mac Catalyst menu-bar commands. Plug into
//  `rishiApp` via:
//
//      WindowGroup { RootView()... }
//          .commands { RishiMenuCommands(router: deps.macCommandRouter) }
//
//  Every command also carries a ⌘ shortcut (sourced from
//  `RishiKeyboardShortcut`) so the keyboard surface and the menu surface
//  stay in sync. iPad hardware-keyboard users get the same chords for free.
//

import SwiftUI

struct RishiMenuCommands: Commands {

    let router: MacCommandRouter

    init(router: MacCommandRouter) {
        self.router = router
    }

    var body: some Commands {
        // Phase 32 Plan 32-03 — native rishi ▸ Settings… (Cmd+,) under the
        // app menu (after the "About" item). Mac-only: iOS/iPadOS keep the
        // in-app gear + sheet (no app menu there). Routes through the same
        // MacCommandRouter as every other command — the actual
        // `openWindow(id: "settings")` happens in MacCommandDispatchModifier
        // (a ViewModifier with the `\.openWindow` env + the single-instance
        // presenter flag), since a Commands body can't reliably hold either.
        #if targetEnvironment(macCatalyst)
        CommandGroup(after: .appInfo) {
            Button("Settings…") { router.send(.showSettings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        #endif

        // FILE — replace the default "New ..." item with our own pair so
        // Catalyst doesn't surface an inert "New Document" menu entry.
        CommandGroup(replacing: .newItem) {
            Button("Import Book…") { router.send(.importBook) }
                .keyboardShortcut(RishiKeyboardShortcut.importBook.key,
                                  modifiers: RishiKeyboardShortcut.importBook.modifiers)
            Button("New Conversation") { router.send(.newConversation) }
                .keyboardShortcut("n", modifiers: .command)
        }

        // EDIT — replace the default Find item so ⌘F focuses our library search.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { router.send(.focusSearch) }
                .keyboardShortcut(RishiKeyboardShortcut.find.key,
                                  modifiers: RishiKeyboardShortcut.find.modifiers)
        }

        // VIEW — theme + font + tab switchers. Phase 32 Plan 32-04: merged
        // into the SINGLE system View menu (created by `.searchable(.toolbar)`
        // in LibrarySearchField.swift) via `CommandGroup(after: .sidebar)`.
        // Previously this declared its own custom View command menu, which
        // collided with SwiftUI's auto-generated View menu and produced TWO
        // "View" menus on Mac. Placing these items after `.sidebar` lands them
        // in the same system View menu — exactly one "View" now appears.
        CommandGroup(after: .sidebar) {
            Button("Light Theme")  { router.send(.selectTheme(.light)) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Sepia Theme")  { router.send(.selectTheme(.sepia)) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Dark Theme")   { router.send(.selectTheme(.dark)) }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button("Increase Font Size") { router.send(.fontIncrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontIncrease.key,
                                  modifiers: RishiKeyboardShortcut.fontIncrease.modifiers)
            Button("Decrease Font Size") { router.send(.fontDecrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontDecrease.key,
                                  modifiers: RishiKeyboardShortcut.fontDecrease.modifiers)
            Divider()
            Button("Library") { router.send(.selectTab(.library)) }
                .keyboardShortcut(RishiKeyboardShortcut.libraryTab.key,
                                  modifiers: RishiKeyboardShortcut.libraryTab.modifiers)
            Button("Chats")   { router.send(.selectTab(.chats)) }
                .keyboardShortcut(RishiKeyboardShortcut.chatsTab.key,
                                  modifiers: RishiKeyboardShortcut.chatsTab.modifiers)
        }

        // WINDOW — extend the system Window menu with a "Reader" jump that
        // routes to the library (where the user picks a book to open).
        CommandGroup(after: .windowArrangement) {
            Button("Reader") { router.send(.selectTab(.library)) }
        }
    }
}

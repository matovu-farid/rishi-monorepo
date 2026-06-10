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

        // VIEW — theme + font + tab switchers.
        CommandMenu("View") {
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

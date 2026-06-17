//
//  RishiKeyboardCommands.swift
//  rishi
//
//  Phase 12 Plan 12-01 — single source of truth for every Cmd-key shortcut
//  exposed on Mac Catalyst (and iPad hardware keyboards). The menu-bar
//  commands in `RishiMenuCommands` and any inline `.keyboardShortcut`
//  modifiers in iOS toolbars MUST reference these constants so the two
//  surfaces stay in lock-step.
//

import SwiftUI
import Foundation

/// Centralised Cmd-key chord table. Adding a new shortcut here once keeps
/// the menu bar, in-app toolbars, and unit tests aligned.
enum RishiKeyboardShortcut {
    case importBook        // ⌘I (NOT ⌘O: collides with the system File > Open)
    case find              // ⌘F
    case fontIncrease      // ⌘+
    case fontDecrease      // ⌘-
    case libraryTab        // ⌘1
    case chatsTab          // ⌘2

    var key: KeyEquivalent {
        switch self {
        case .importBook:   return "i"
        case .find:         return "f"
        case .fontIncrease: return "+"
        case .fontDecrease: return "-"
        case .libraryTab:   return "1"
        case .chatsTab:     return "2"
        }
    }

    var modifiers: EventModifiers { .command }
}

/// All command intents the Mac menu bar (and ⌘ shortcuts) can fire.
/// Carries no payload — `RootView` resolves the active book/conversation
/// from its own `@State` when consuming.
enum MacCommandIntent: Equatable, Sendable {
    case importBook
    case newConversation
    case focusSearch
    case fontIncrease
    case fontDecrease
    case selectTheme(MacReaderTheme)
    case selectTab(MacTab)
    case pageForward
    case pageBackward
    case showSettings
}

/// Two-tab top-level navigation surface for Mac menu commands.
///
/// `Codable` (Phase 12 Plan 12-02) so `RishiSceneState` can round-trip the
/// selected tab through a `@SceneStorage` JSON cell. `String` rawValue
/// gives us the encoder/decoder for free.
enum MacTab: String, Equatable, Sendable, Codable { case library, chats }

/// Local Mac/-folder echo of `RishiReader.ReaderTheme`. Kept here so the
/// router + menu can be unit-tested without dragging the RishiReader
/// package into the app-target test bundle's transitive imports.
/// `RootView` maps this enum to the real reader theme when consuming.
enum MacReaderTheme: String, Equatable, Sendable { case light, sepia, dark }

/// NotificationCenter names used to bridge router intents into views that
/// live inside SwiftPM packages (`RishiLibrary`, `RishiReader`) without
/// forcing them to depend on the `rishi` app target.
enum RishiCommand {
    static let importBook   = Notification.Name("RishiCommand.importBook")
    static let focusSearch  = Notification.Name("RishiCommand.focusSearch")
    static let pageForward  = Notification.Name("RishiCommand.pageForward")
    static let pageBackward = Notification.Name("RishiCommand.pageBackward")
    /// Userinfo carries `["delta": Int]` (+1 = larger, -1 = smaller). Reader
    /// screens observe this and call their VM's typography accessors.
    static let fontStep     = Notification.Name("RishiCommand.fontStep")
    /// Userinfo carries `["delta": Int]` for the font-step value.
    static let fontStepDeltaKey = "delta"
}














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
        _ = commands.body  
        #expect(router.pendingIntent == nil)
    }

    @Test("Router is held by reference (menu taps reach the same instance)")
    func routerHeldByReference() {
        let router = MacCommandRouter()
        let commands = RishiMenuCommands(router: router, account: MacAccountMenuModel())
        
        
        router.send(.focusSearch)
        #expect(commands.router.pendingIntent == .focusSearch)
        commands.router.consume()
        #expect(router.pendingIntent == nil)
    }

    
    
    
    
    
    
    
    
    
    @Test("Import Book shortcut avoids the system-reserved File > Open (Cmd+O)")
    func importShortcutAvoidsSystemOpenCollision() {
        let shortcut = RishiKeyboardShortcut.importBook
        let collidesWithSystemOpen =
            shortcut.key.character == "o" && shortcut.modifiers == .command
        #expect(
            collidesWithSystemOpen == false,
            "Import Book must not use ⌘O — it collides with the system File > Open command on Mac"
        )
        
        #expect(shortcut.key.character == "i")
        #expect(shortcut.modifiers == .command)
    }

    
    
    
    
    
    
    
    
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

    
    
    
    
    
    
    
    
    
    
    
    
    @Test("Find in Book + Add Bookmark intents round-trip through MacCommandRouter")
    func readerAffordanceIntentsRoundTrip() {
        let router = MacCommandRouter()

        
        
        router.send(.focusSearch)
        #expect(router.pendingIntent == .focusSearch)
        router.consume()

        
        router.send(.addBookmark)
        #expect(router.pendingIntent == .addBookmark)
        #expect(RishiKeyboardShortcut.addBookmark.key == "d")
        #expect(RishiKeyboardShortcut.addBookmark.modifiers == .command)
        router.consume()

        #expect(router.pendingIntent == nil)
    }

    
    
    
    
    @Test("Add Bookmark (⌘D) does not collide with the Find (⌘F) chord")
    func addBookmarkChordDoesNotCollideWithFind() {
        let bookmark = RishiKeyboardShortcut.addBookmark
        let find = RishiKeyboardShortcut.find
        let sameChord =
            bookmark.key.character == find.key.character
            && bookmark.modifiers == find.modifiers
        #expect(sameChord == false)
        #expect(bookmark.key.character == "d")
        #expect(find.key.character == "f")
    }
}

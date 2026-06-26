

import SwiftUI
import Foundation


enum RishiKeyboardShortcut {
    case importBook        
    case find              
    case addBookmark       
    case fontIncrease      
    case fontDecrease      
    case libraryTab        
    case chatsTab          

    var key: KeyEquivalent {
        switch self {
        case .importBook:   return "i"
        case .find:         return "f"
        case .addBookmark:  return "d"
        case .fontIncrease: return "+"
        case .fontDecrease: return "-"
        case .libraryTab:   return "1"
        case .chatsTab:     return "2"
        }
    }

    var modifiers: EventModifiers { .command }
}


enum MacCommandIntent: Equatable, Sendable {
    case importBook
    case newConversation
    case focusSearch
    case addBookmark
    case fontIncrease
    case fontDecrease
    case selectTheme(MacReaderTheme)
    case selectTab(MacTab)
    case pageForward
    case pageBackward
}


enum MacTab: String, Equatable, Sendable, Codable { case library, chats }


enum MacReaderTheme: String, Equatable, Sendable { case light, sepia, dark }


enum RishiCommand {
    static let importBook   = Notification.Name("RishiCommand.importBook")
    static let focusSearch  = Notification.Name("RishiCommand.focusSearch")

    static let addBookmark  = Notification.Name("RishiCommand.addBookmark")
    static let pageForward  = Notification.Name("RishiCommand.pageForward")
    static let pageBackward = Notification.Name("RishiCommand.pageBackward")

    static let fontStep     = Notification.Name("RishiCommand.fontStep")
    
    static let fontStepDeltaKey = "delta"
}

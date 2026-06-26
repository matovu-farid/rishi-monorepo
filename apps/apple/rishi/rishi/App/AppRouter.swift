

import SwiftUI
import RishiCore
import RishiReader



struct ConversationsRoute: Hashable {}



@MainActor
@Observable
final class AppRouter {

    

    
    var path: NavigationPath = NavigationPath()

    
    
    
    

    

    private let deepLinks = DeepLinkRouter()

    


    var onBookResolved: ((Book) -> Void)?

    var onConversationResolved: ((Conversation) -> Void)?


    var onFileURL: ((URL) -> Void)?


    func handle(
        url: URL,
        bookStore: (any BookStore)?,
        conversationStore: (any ConversationStore)?
    ) {
        let destination = deepLinks.route(url)
        switch destination {
        case .authCallback:
            
            
            
            
            
            
            break

        case .shareRedeem(let token):
            
            
            _ = token

        case .openBook(let bookId):
            guard let bookStore else { return }
            
            Task {
                let book: Book? = try? await bookStore.book(bookId)
                guard let book else { return }
                
                onBookResolved?(book)
                
                var p = NavigationPath()
                p.append(ReaderRoute.route(for: book))
                path = p
            }

        case .openConversation(let conversationId):
            guard let conversationStore else { return }
            
            Task {
                let convo: Conversation? = try? await conversationStore.conversation(conversationId)
                guard let convo else { return }
                onConversationResolved?(convo)
            }

        case .unknown:
            
            
            if url.isFileURL {
                onFileURL?(url)
            }
        }
    }

    

    
    func showLibraryRoot() {
        path = NavigationPath()
    }

    
    func showConversations() {
        var p = NavigationPath()
        p.append(ConversationsRoute())
        path = p
    }


    func applyRestored(
        tabRaw _: String,
        openBookIdRaw _: String,
        bookStore _: (any BookStore)?
    ) async {
        
    }


    func persistCells() -> (tabRaw: String, openBookIdRaw: String) {
        
        
        let state = RishiSceneState(selectedTab: .library, openBookId: nil)
        let tabRaw = state.encodeForStorage()
        let openBookIdRaw = NavigationPath.encodeForStorage(path)
        return (tabRaw: tabRaw, openBookIdRaw: openBookIdRaw)
    }
}

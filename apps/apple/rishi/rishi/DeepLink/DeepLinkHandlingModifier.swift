

import SwiftUI
import RishiCore
import RishiLibrary

struct DeepLinkHandlingModifier: ViewModifier {

    let model: SignedInViewModel


    @Environment(AppRouter.self) private var router
    @Environment(\.services) private var servicesEnv
    @Environment(LibraryViewModel.self) private var libraryVM

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let services = servicesEnv else { return }
                router.onBookResolved = { book in
                    model.hint(book)
                }
                router.onConversationResolved = { convo in
                    model.present(conversation: convo)
                }
                router.onFileURL = { [libraryVM] fileURL in
                    
                    Task {
                        _ = await services.importCoordinator.importBooks([fileURL])
                        await libraryVM.refresh()
                    }
                }
                router.handle(
                    url: url,
                    bookStore: services.bookStore,
                    conversationStore: services.conversationStore
                )
            }
    }
}

extension View {
    func deepLinkHandling(model: SignedInViewModel,) -> some View {
        modifier(DeepLinkHandlingModifier(model: model))
    }
}

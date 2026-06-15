//
//  DeepLinkHandlingModifier.swift
//  rishi
//
//  Phase D5 refactor — extracts the `.onOpenURL` deep-link wiring block from
//  LibraryTabView into a self-contained ViewModifier. Sets the three router
//  callbacks and calls router.handle(url:bookStore:conversationStore:).
//

import SwiftUI
import RishiCore
import RishiLibrary

struct DeepLinkHandlingModifier: ViewModifier {

    let services: BootstrappedServices
    let model: SignedInViewModel
    let libraryVM: LibraryViewModel

    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
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
    func deepLinkHandling(services: BootstrappedServices, model: SignedInViewModel, libraryVM: LibraryViewModel) -> some View {
        modifier(DeepLinkHandlingModifier(services: services, model: model, libraryVM: libraryVM))
    }
}

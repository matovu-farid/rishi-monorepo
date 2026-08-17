

import SwiftUI



struct DeepLinkHandlingModifier: ViewModifier {

    let model: SignedInViewModel
    let refreshLibrary: () async -> Void
    let currentUserID: UserID


    @Environment(AppRouter.self) private var router
    @Environment(\.services) private var servicesEnv

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
                router.onFileURL = { fileURL in
                    Task {
                        _ = await services.library.importCoordinator.importBooks([fileURL])
                        await refreshLibrary()
                    }
                }
                router.handle(
                    url: url,
                    bookStore: services.library.bookStore,
                    conversationStore: services.chat.conversationStore,
                    currentUserID: currentUserID
                )
            }
            .task {
                guard let services = servicesEnv else { return }
                await router.drainPendingAccountURLs(
                    bookStore: services.library.bookStore,
                    conversationStore: services.chat.conversationStore,
                    currentUserID: currentUserID
                )
            }
    }
}

extension View {
    func deepLinkHandling(
        model: SignedInViewModel,
        refreshLibrary: @escaping () async -> Void,
        currentUserID: UserID
    ) -> some View {
        modifier(
            DeepLinkHandlingModifier(
                model: model,
                refreshLibrary: refreshLibrary,
                currentUserID: currentUserID
            )
        )
    }
}

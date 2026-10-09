

import SwiftUI



struct DeepLinkHandlingModifier: ViewModifier {

    let model: SignedInViewModel
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
                router.handle(
                    url: url,
                    bookStore: services.library.bookStore,
                    conversationStore: services.chat.conversationStore,
                    currentUserID: currentUserID,
                    beforePresentingBook: {
                        services.voice.presenter.scheduleRegisteredReaderCleanup()
                        return true
                    }
                )
            }
            .task {
                guard let services = servicesEnv else { return }
                await router.drainPendingAccountURLs(
                    bookStore: services.library.bookStore,
                    conversationStore: services.chat.conversationStore,
                    currentUserID: currentUserID,
                    beforePresentingBook: {
                        services.voice.presenter.scheduleRegisteredReaderCleanup()
                        return true
                    }
                )
            }
    }
}

extension View {
    func deepLinkHandling(
        model: SignedInViewModel,
        currentUserID: UserID
    ) -> some View {
        modifier(
            DeepLinkHandlingModifier(
                model: model,
                currentUserID: currentUserID
            )
        )
    }
}

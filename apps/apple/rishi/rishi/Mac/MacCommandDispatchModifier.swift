

import SwiftUI


struct MacCommandDispatchModifier: ViewModifier {

    let readerDefaults: AppReaderDefaults

    @Environment(AppRouter.self) private var router
    @Environment(\.macCommandRouter) private var commandRouter
    #if targetEnvironment(macCatalyst)
        @Environment(ReaderWindowCoordinator.self) private var readerWindows
    #endif

    func body(content: Content) -> some View {
        content
            .task(id: commandRouter?.pendingIntent) {
                consume()
            }
    }

    

    private func consume() {
        guard let cmdRouter = commandRouter, let intent = cmdRouter.pendingIntent else { return }
        defer { cmdRouter.consume() }

        switch intent {
        case .importBook:
            router.showLibraryRoot()
            NotificationCenter.default.post(name: RishiCommand.importBook, object: nil)

        case .newConversation:
            router.showConversations()

        case .focusSearch:
            router.showLibraryRoot()
            NotificationCenter.default.post(name: RishiCommand.focusSearch, object: nil)

        case .addBookmark:
            
            
            
            
            NotificationCenter.default.post(name: RishiCommand.addBookmark, object: nil)

        case .fontIncrease:
            NotificationCenter.default.post(
                name: RishiCommand.fontStep, object: nil,
                userInfo: [RishiCommand.fontStepDeltaKey: +1]
            )

        case .fontDecrease:
            NotificationCenter.default.post(
                name: RishiCommand.fontStep, object: nil,
                userInfo: [RishiCommand.fontStepDeltaKey: -1]
            )

        case .selectTheme(let macTheme):
            readerDefaults.theme = mapReaderTheme(macTheme)

        case .selectTab(let tab):
            switch tab {
            case .library: router.showLibraryRoot()
            case .chats:   router.showConversations()
            }

        case .pageForward:
            postPageCommand(RishiCommand.pageForward)

        case .pageBackward:
            postPageCommand(RishiCommand.pageBackward)
        }
    }

    private func postPageCommand(_ name: Notification.Name) {
        #if targetEnvironment(macCatalyst)
            guard let bookID = readerWindows.activeReader?.id.bookID else { return }
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: [RishiCommand.targetBookIDKey: bookID]
            )
        #else
            NotificationCenter.default.post(name: name, object: nil)
        #endif
    }

    private func mapReaderTheme(_ macTheme: MacReaderTheme) -> ReaderTheme {
        switch macTheme {
        case .matchDevice: return .matchDevice
        case .light: return .light
        case .sepia: return .sepia
        case .dark:  return .dark
        }
    }
}

extension View {
    func macCommandDispatch(readerDefaults: AppReaderDefaults) -> some View {
        modifier(MacCommandDispatchModifier(readerDefaults: readerDefaults))
    }
}

//
//  MacCommandDispatchModifier.swift
//  rishi
//
//  Phase D5 refactor — extracts the Mac command intent dispatch block from
//  SignedInView into a self-contained ViewModifier. Reads the
//  macCommandRouter from the SwiftUI environment and fires on every
//  pendingIntent change via `.task(id:)`.
//

import SwiftUI
import RishiReader

struct MacCommandDispatchModifier: ViewModifier {

    let readerDefaults: AppReaderDefaults

    @Environment(AppRouter.self) private var router
    @Environment(\.macCommandRouter) private var commandRouter
    // Phase 32 Plan 32-03 — `openWindow` is environment-only (cannot live in a
    // Commands body), so the Settings… menu item routes `.showSettings` here
    // and this ViewModifier (already mounted on SignedInView) opens the window.
    // `deps` reaches the shared `settingsWindowPresenter` single-instance flag.
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appDependencies) private var deps

    func body(content: Content) -> some View {
        content
            .task(id: commandRouter?.pendingIntent) {
                consume()
            }
    }

    // MARK: - Private

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

        case .showSettings:
            // Phase 32 Plan 32-03 — open the dedicated Settings window only
            // when it is not already open (single-instance backstop, Pitfall
            // 2). The presenter flag is flipped by SettingsWindowRoot's
            // onAppear/onDisappear, so a second Cmd+, while open is a no-op
            // here (and the OS keeps the existing window focused). Mac-only.
            #if targetEnvironment(macCatalyst)
            if deps?.settingsWindowPresenter.shouldOpen ?? true {
                openWindow(id: "settings")
            }
            #endif

        case .pageForward:
            NotificationCenter.default.post(name: RishiCommand.pageForward, object: nil)

        case .pageBackward:
            NotificationCenter.default.post(name: RishiCommand.pageBackward, object: nil)
        }
    }

    private func mapReaderTheme(_ macTheme: MacReaderTheme) -> ReaderTheme {
        switch macTheme {
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

//
//  SceneRestorationModifier.swift
//  rishi
//
//  Phase D5 refactor — extracts the scene-restoration task and path-persist
//  onChange from SignedInView into a self-contained ViewModifier. The
//  `sceneRestored` one-shot guard lives as a private @State inside the
//  modifier so it is per-instance and identical to the original inline behaviour.
//

import SwiftUI
import RishiCore

struct SceneRestorationModifier: ViewModifier {

    let model: SignedInViewModel
    @Binding var tabRaw: String
    @Binding var openBookIdRaw: String

    @Environment(AppRouter.self) private var router
    @Environment(\.services) private var servicesEnv

    /// Guards the scene-restoration task so it only fires once per scene
    /// instance. Matches the original `@State private var sceneRestored` in
    /// SignedInView.
    @State private var sceneRestored = false

    func body(content: Content) -> some View {
        content
            // Phase 12 Plan 12-02 (MAC-05) — restore selected tab + reader cover.
            .task {
                guard !sceneRestored else { return }
                sceneRestored = true
                guard let services = servicesEnv else { return }
                router.onBookResolved = { book in
                    model.hint(book)
                }
                await router.applyRestored(
                    tabRaw: tabRaw,
                    openBookIdRaw: openBookIdRaw,
                    bookStore: services.bookStore
                )
            }
            // Persist the latest scene state on every visible path change.
            .onChange(of: router.path) { _, _ in
                let cells = router.persistCells()
                tabRaw = cells.tabRaw
                openBookIdRaw = cells.openBookIdRaw
            }
    }
}

extension View {
    func sceneRestoration(
        model: SignedInViewModel,
        tabRaw: Binding<String>,
        openBookIdRaw: Binding<String>
    ) -> some View {
        modifier(SceneRestorationModifier(
            model: model,
            tabRaw: tabRaw,
            openBookIdRaw: openBookIdRaw
        ))
    }
}

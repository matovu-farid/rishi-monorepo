









import SwiftUI


struct SceneRestorationModifier: ViewModifier {

    let model: SignedInViewModel
    @Binding var tabRaw: String
    @Binding var openBookIdRaw: String

    @Environment(AppRouter.self) private var router
    @Environment(\.services) private var servicesEnv

    
    
    
    @State private var sceneRestored = false

    func body(content: Content) -> some View {
        content
            
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
                    bookStore: services.library.bookStore
                )
            }
            
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

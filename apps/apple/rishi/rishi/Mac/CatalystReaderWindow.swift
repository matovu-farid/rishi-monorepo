import SwiftUI




#if targetEnvironment(macCatalyst)

struct ReaderWindowCoordinatorConfiguration: ViewModifier {
    let coordinator: ReaderWindowCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .task {
                coordinator.configure(
                    openWindow: openWindow,
                    dismissWindow: dismissWindow
                )
            }
    }
}

struct CatalystReaderWindow: View {
    let input: ReaderWindowInput
    @State private var presentationState = PDFReaderPresentationState()

    @Environment(\.appDependencies) private var appDependencies
    @Environment(CurrentUserBox.self) private var currentUser
    @Environment(ReaderWindowCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var presentation = presentationState
        Group {
            if let services = appDependencies?.services,
               let user = signedInUser,
               user.id == input.id.userID {
                NavigationStack {
                    ReaderDestinationView(
                        route: input.route,
                        hint: nil,
                        onRequestPaywall: { _ in },
                        pdfViewMode: $presentation.requestedMode
                    )
                }
                .readerPrefsMenuPublisher(
                    services: services,
                    user: user,
                    onSignedOut: {},
                    account: nil
                )
                .focusedSceneValue(\.pdfReaderFocusedMenu, isPDFReader ? PDFReaderFocusedMenuModel(
                    pdfViewMode: $presentation.requestedMode
                ) : nil)
                .toolbarBackground(.visible, for: .navigationBar)
                .onAppear { coordinator.register(input) }
                .onDisappear { coordinator.unregister(input) }
                .environment(\.services, services)
                .task {
                    guard case .pdf = input.route else { return }
                    presentation.requestedMode = services.readerDefaults.pdfViewMode
                    presentation.didApply(mode: presentation.requestedMode)
                }
                .onChange(of: presentation.requestedMode) { _, mode in
                    guard isPDFReader else { return }
                    presentation.beginTransition(to: mode)
                    services.readerDefaults.pdfViewMode = mode
                    presentation.didApply(mode: mode)
                }
            } else {
                ContentUnavailableView(
                    "Reader unavailable",
                    systemImage: "book.closed",
                    description: Text("This book is no longer available for the signed-in account.")
                )
            }
        }
    }

    private var isPDFReader: Bool {
        if case .pdf = input.route { return true }
        return false
    }

    private var signedInUser: User? {
        guard case .signedIn(let user) = currentUser.state else { return nil }
        return user
    }
}

#endif

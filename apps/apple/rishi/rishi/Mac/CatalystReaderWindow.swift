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
    @Environment(\.scenePhase) private var scenePhase

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
                    account: nil,
                    pdfViewMode: $presentation.requestedMode
                )
                .toolbarBackground(.visible, for: .navigationBar)
                .onAppear {
                    coordinator.activate(
                        input,
                        theme: services.readerDefaults.theme,
                        pdfViewMode: isPDFReader ? services.readerDefaults.pdfViewMode : nil
                    )
                }
                .onDisappear { coordinator.unregister(input) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.activate(
                            input,
                            theme: services.readerDefaults.theme,
                            pdfViewMode: isPDFReader ? services.readerDefaults.pdfViewMode : nil
                        )
                    } else {
                        coordinator.deactivate(input)
                    }
                }
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
                    coordinator.updateActivePDFViewMode(mode)
                    presentation.didApply(mode: mode)
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .rishiPDFViewModeChanged
                    )
                ) { note in
                    guard isPDFReader,
                          let mode = note.object as? PDFViewModeSetting,
                          presentation.requestedMode != mode else { return }
                    coordinator.updateActivePDFViewMode(mode)
                    presentation.requestedMode = mode
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .rishiReaderThemeChanged
                    )
                ) { note in
                    guard let theme = note.object as? ReaderTheme else { return }
                    coordinator.updateActiveTheme(theme)
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

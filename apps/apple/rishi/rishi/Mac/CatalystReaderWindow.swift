import SwiftUI
import UIKit




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
                .background {
                    ReaderWindowKeyObserver {
                        guard scenePhase == .active else { return }
                        coordinator.activate(
                            input,
                            theme: services.settings.readerDefaults.theme,
                            pdfViewMode: isPDFReader ? services.settings.readerDefaults.pdfViewMode : nil
                        )
                    }
                    .frame(width: 0, height: 0)
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
                        theme: services.settings.readerDefaults.theme,
                        pdfViewMode: isPDFReader ? services.settings.readerDefaults.pdfViewMode : nil
                    )
                }
                .onDisappear { coordinator.unregister(input) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        coordinator.activate(
                            input,
                            theme: services.settings.readerDefaults.theme,
                            pdfViewMode: isPDFReader ? services.settings.readerDefaults.pdfViewMode : nil
                        )
                    } else {
                        coordinator.deactivate(input)
                    }
                }
                .environment(\.services, services)
                .task {
                    guard case .pdf = input.route else { return }
                    presentation.requestedMode = services.settings.readerDefaults.pdfViewMode
                    presentation.didApply(mode: presentation.requestedMode)
                }
                .onChange(of: presentation.requestedMode) { _, mode in
                    guard isPDFReader else { return }
                    presentation.beginTransition(to: mode)
                    services.settings.readerDefaults.pdfViewMode = mode
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

private struct ReaderWindowKeyObserver: UIViewRepresentable {
    let onBecameKey: () -> Void

    func makeUIView(context: Context) -> KeyWindowProbeView {
        let view = KeyWindowProbeView()
        view.onBecameKey = onBecameKey
        return view
    }

    func updateUIView(_ uiView: KeyWindowProbeView, context: Context) {
        uiView.onBecameKey = onBecameKey
    }
}

private final class KeyWindowProbeView: UIView {
    var onBecameKey: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey(_:)),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window?.isKeyWindow == true {
            onBecameKey?()
        }
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let keyWindow = note.object as? UIWindow,
              keyWindow === window else { return }
        onBecameKey?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

#endif

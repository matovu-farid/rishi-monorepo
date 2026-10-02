import Observation
import SwiftUI

public struct ReaderMoreMenuPresentationKey: EnvironmentKey {
    public static let defaultValue: ReaderMoreMenuPresentation? = nil
}

public extension EnvironmentValues {
    var readerMoreMenuPresentation: ReaderMoreMenuPresentation? {
        get { self[ReaderMoreMenuPresentationKey.self] }
        set { self[ReaderMoreMenuPresentationKey.self] = newValue }
    }
}

/// Coordinates the More popover with reader chrome visibility.
@MainActor
@Observable
public final class ReaderMoreMenuPresentation {
    private(set) var isPresented = false

    @ObservationIgnored private let chrome: ReaderChromeController
    @ObservationIgnored private var pendingAction: (@MainActor () -> Void)?

    public init(chrome: ReaderChromeController) {
        self.chrome = chrome
    }

    public var binding: Binding<Bool> {
        Binding(
            get: { self.isPresented },
            set: { self.setPresented($0) }
        )
    }

    /// Close the popover before running an action that may present a sheet.
    public func dismiss(then action: @escaping @MainActor () -> Void) {
        pendingAction = action
        setPresented(false)
    }

    private func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented

        if presented {
            chrome.pauseAutoHide()
            return
        }

        chrome.resumeAutoHide()
        guard pendingAction != nil else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.runPendingAction()
        }
    }

    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
    }
}

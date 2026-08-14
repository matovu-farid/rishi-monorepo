#if os(iOS) && canImport(CarPlay)
import CarPlay
import Foundation
import UIKit

@MainActor
final class CarPlaySessionCoordinator {
    private let dependencies: AppDependencies
    private let services: BootstrappedServices
    private let interfaceController: CPInterfaceController
    private let playback: CarPlayPlaybackCoordinator
    private let loader: CarPlayCatalogLoader
    private var rowIDs: Set<BookID> = []
    private var catalogAccountSnapshot: CarPlayAccountSnapshot?
    private var lifecycleToken = UUID()
    private var refreshTask: Task<Void, Never>?
    private var isActive = true
    private var accountObserverToken: UUID?

    static func isCatalogCurrent(
        _ catalogAccountSnapshot: CarPlayAccountSnapshot?,
        current currentAccountSnapshot: CarPlayAccountSnapshot?
    ) -> Bool {
        guard let catalogAccountSnapshot, let currentAccountSnapshot else { return false }
        return catalogAccountSnapshot == currentAccountSnapshot
    }

    init(
        dependencies: AppDependencies,
        services: BootstrappedServices,
        interfaceController: CPInterfaceController
    ) {
        self.dependencies = dependencies
        self.services = services
        self.interfaceController = interfaceController
        let host = UUID()
        let driver = ReadAloudCarPlayDriver(
            services: services,
            owner: services.audio.playbackOwner,
            host: host,
            accountSnapshot: { [weak dependencies] in dependencies?.carPlayAccountSnapshot }
        )
        self.playback = CarPlayPlaybackCoordinator(
            driver: driver,
            accountSnapshot: { [weak dependencies] in dependencies?.carPlayAccountSnapshot },
            entitlementGate: { [weak dependencies] in
                guard let dependencies, let services = dependencies.services else { return false }
                return await EntitlementAIGate.gateAIFeature(
                    .narration,
                    store: services.billing.entitlementSnapshotStore,
                    coordinator: services.billing.entitlementRefreshCoordinator
                ) == nil
            }
        )
        self.loader = CarPlayCatalogLoader(
            bookStore: services.library.bookStore,
            positionStore: services.library.positionStore,
            bookFileStorage: services.library.bookFileStorage,
            accountSnapshot: { [weak dependencies] in dependencies?.carPlayAccountSnapshot }
        )
        accountObserverToken = dependencies.addCarPlayAccountChangeObserver { [weak self] _ in
            self?.accountDidChange()
        }
    }

    func refresh() async {
        guard isActive else { return }
        refreshTask?.cancel()
        let token = UUID()
        lifecycleToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(token: token)
        }
        refreshTask = task
        await task.value
        if lifecycleToken == token {
            refreshTask = nil
        }
    }

    func disconnect() async {
        isActive = false
        lifecycleToken = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        if let accountObserverToken {
            dependencies.removeCarPlayAccountChangeObserver(accountObserverToken)
            self.accountObserverToken = nil
        }
        await playback.disconnect()
        rowIDs.removeAll()
        catalogAccountSnapshot = nil
    }

    private func accountDidChange() {
        guard isActive else { return }
        refreshTask?.cancel()
        lifecycleToken = UUID()
        clearCatalog()
        if let account = dependencies.carPlayAccountSnapshot {
            install(
                status: "Loading Rishi…",
                token: lifecycleToken,
                capturedAccount: account
            )
        } else {
            install(
                status: "Sign in on iPhone to listen",
                token: lifecycleToken,
                capturedAccount: nil
            )
        }
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    private func performRefresh(token: UUID) async {
        var capturedAccount = dependencies.carPlayAccountSnapshot
        var didRetryForCurrentAccount = false

        while true {
            guard lifecycleToken == token, isActive, !Task.isCancelled else { return }

            guard let account = capturedAccount else {
                clearCatalog()
                install(
                    status: "Sign in on iPhone to listen",
                    token: token,
                    capturedAccount: nil
                )
                return
            }

            guard dependencies.carPlayAccountSnapshot == account else {
                guard recoverFromStaleRefresh(
                    token: token,
                    capturedAccount: &capturedAccount,
                    didRetry: &didRetryForCurrentAccount
                ) else { return }
                continue
            }

            do {
                try Task.checkCancellation()
                guard lifecycleToken == token, isActive else { return }
                guard dependencies.carPlayAccountSnapshot == account else {
                    guard recoverFromStaleRefresh(
                        token: token,
                        capturedAccount: &capturedAccount,
                        didRetry: &didRetryForCurrentAccount
                    ) else { return }
                    continue
                }

                guard let snapshot = try await loader.load(perSectionCap: 12) else {
                    try Task.checkCancellation()
                    guard recoverFromStaleRefresh(
                        token: token,
                        capturedAccount: &capturedAccount,
                        didRetry: &didRetryForCurrentAccount
                    ) else { return }
                    continue
                }

                guard lifecycleToken == token,
                      isActive,
                      !Task.isCancelled,
                      dependencies.carPlayAccountSnapshot == account
                else { return }
                install(snapshot: snapshot, token: token, capturedAccount: account)
                return
            } catch is CancellationError {
                return
            } catch {
                guard lifecycleToken == token,
                      isActive,
                      !Task.isCancelled
                else { return }
                guard dependencies.carPlayAccountSnapshot == account else {
                    guard recoverFromStaleRefresh(
                        token: token,
                        capturedAccount: &capturedAccount,
                        didRetry: &didRetryForCurrentAccount
                    ) else { return }
                    continue
                }
                install(
                    status: "Library unavailable",
                    token: token,
                    capturedAccount: account
                )
                return
            }
        }
    }

    private func recoverFromStaleRefresh(
        token: UUID,
        capturedAccount: inout CarPlayAccountSnapshot?,
        didRetry: inout Bool
    ) -> Bool {
        guard lifecycleToken == token, isActive, !Task.isCancelled else { return false }

        let currentAccount = dependencies.carPlayAccountSnapshot
        clearCatalog()
        if let currentAccount {
            install(
                status: "Loading Rishi…",
                token: token,
                capturedAccount: currentAccount
            )
            guard !didRetry else { return false }
            capturedAccount = currentAccount
            didRetry = true
            return true
        }

        install(
            status: "Sign in on iPhone to listen",
            token: token,
            capturedAccount: nil
        )
        return false
    }

    private func clearCatalog() {
        rowIDs.removeAll()
        catalogAccountSnapshot = nil
    }

    private func canInstall(
        token: UUID,
        capturedAccount: CarPlayAccountSnapshot?
    ) -> Bool {
        lifecycleToken == token &&
            isActive &&
            !Task.isCancelled &&
            dependencies.carPlayAccountSnapshot == capturedAccount
    }

    private func install(
        snapshot: CarPlayCatalogSnapshot,
        token: UUID,
        capturedAccount: CarPlayAccountSnapshot
    ) {
        guard canInstall(token: token, capturedAccount: capturedAccount) else { return }
        catalogAccountSnapshot = capturedAccount
        rowIDs = Set(snapshot.sections.flatMap(\.rows).map(\.id))
        var sections: [CPListSection] = []
        for section in snapshot.sections where !section.rows.isEmpty {
            let items = section.rows.map(makeItem)
            let title = section.kind == .continueListening ? "Continue Listening" : "Library"
            sections.append(CPListSection(items: items, header: title, sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            install(
                status: "No downloaded EPUB books",
                token: token,
                capturedAccount: capturedAccount
            )
        } else {
            interfaceController.setRootTemplate(
                CPListTemplate(title: "Rishi", sections: sections),
                animated: true
            )
        }
    }

    private func install(
        status: String,
        token: UUID,
        capturedAccount: CarPlayAccountSnapshot?
    ) {
        guard canInstall(token: token, capturedAccount: capturedAccount) else { return }
        let item = CPListItem(text: status, detailText: nil)
        item.isEnabled = false
        interfaceController.setRootTemplate(
            CPListTemplate(title: "Rishi", sections: [CPListSection(items: [item])]),
            animated: true
        )
    }

    private func makeItem(_ row: CarPlayBookRow) -> any CPListTemplateItem {
        let image = image(for: row)
        let selectionHandler = selectionHandler(for: row.id)

        if #available(iOS 26.0, *) {
            let element = CPListImageRowItemRowElement(
                image: image,
                title: row.title,
                subtitle: row.displayDetail
            )
            let item = CPListImageRowItem(
                text: nil,
                elements: [element],
                allowsMultipleLines: false
            )
            item.handler = selectionHandler
            item.listImageRowHandler = { item, _, completion in
                selectionHandler(item, completion)
            }
            return item
        }

        let item = CPListItem(text: row.title, detailText: row.displayDetail, image: image)
        item.handler = selectionHandler
        return item
    }

    @MainActor
    private func image(for row: CarPlayBookRow) -> UIImage {
        guard let coverData = row.coverData,
              let image = UIImage(data: coverData)
        else {
            return UIImage(systemName: "book.closed.fill") ?? UIImage()
        }
        return image
    }

    private func selectionHandler(
        for bookID: BookID
    ) -> (any CPSelectableListItem, @escaping () -> Void) -> Void {
        { [weak self] _, completion in
            Task { @MainActor in
                defer { completion() }
                await self?.select(bookID)
            }
        }
    }

    private func select(_ bookID: BookID) async {
        guard dependencies.carPlayAccountSnapshot != nil else {
            rowIDs.removeAll()
            catalogAccountSnapshot = nil
            install(
                status: "Sign in on iPhone to listen",
                token: lifecycleToken,
                capturedAccount: nil
            )
            return
        }
        guard rowIDs.contains(bookID),
              Self.isCatalogCurrent(
                  catalogAccountSnapshot,
                  current: dependencies.carPlayAccountSnapshot
              )
        else {
            clearCatalog()
            install(
                status: "Book unavailable",
                token: lifecycleToken,
                capturedAccount: dependencies.carPlayAccountSnapshot
            )
            return
        }
        do {
            let result = try await playback.select(bookID: bookID)
            switch result {
            case .started, .toggled:
                CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
                try? await interfaceController.pushTemplate(
                    CPNowPlayingTemplate.shared,
                    animated: true
                )
            case .entitlementRequired:
                presentAlert("Narration is unavailable", message: "Open Rishi on iPhone to manage narration access.")
            case .signedOut, .staleAccount:
                install(
                    status: "Sign in on iPhone to listen",
                    token: lifecycleToken,
                    capturedAccount: dependencies.carPlayAccountSnapshot
                )
            }
        } catch {
            presentAlert("Playback unavailable", message: "This book could not be started.")
            await refresh()
        }
    }

    private func presentAlert(_ title: String, message: String) {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        interfaceController.presentTemplate(
            CPAlertTemplate(titleVariants: [title], actions: [action]),
            animated: true
        )
    }
}
#endif

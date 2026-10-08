#if os(iOS) && canImport(CarPlay)
import CarPlay
import Foundation
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var session: CarPlaySessionCoordinator?
    private var connectionID: UUID?
    private weak var connectedInterfaceController: CPInterfaceController?

    static func isCurrentInterfaceController(
        connected: ObjectIdentifier?,
        callback: ObjectIdentifier
    ) -> Bool {
        connected == callback
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let previousSession = session
        session = nil
        connectedInterfaceController = interfaceController
        if let previousSession {
            Task { @MainActor in
                await previousSession.disconnect()
            }
        }

        let loadingItem = CPListItem(text: "Loading Rishi…", detailText: nil)
        loadingItem.isEnabled = false
        interfaceController.setRootTemplate(
            CPListTemplate(
                title: "Rishi",
                sections: [CPListSection(items: [loadingItem])]
            ),
            animated: false
        )

        let dependencies = AppDependencies.shared
        let connectionID = UUID()
        self.connectionID = connectionID
        Task { @MainActor [weak self] in
            let snapshot: RishiAppIntentSnapshot
            do { snapshot = try await RishiAppIntentRuntime.snapshot() }
            catch {
                guard self?.connectionID == connectionID else { return }
                Self.showUnavailable(on: interfaceController, detail: error.localizedDescription)
                return
            }
            guard self?.connectionID == connectionID,
                  dependencies.carPlayAccountSnapshot == CarPlayAccountSnapshot(userID: snapshot.userID,
                      generation: snapshot.authorizationGeneration) else { return }
            let services = snapshot.services
            let session = CarPlaySessionCoordinator(
                dependencies: dependencies,
                services: services,
                interfaceController: interfaceController
            )
            guard self?.connectionID == connectionID else { return }
            self?.session = session
            await session.refresh()
        }
    }

    private static func showUnavailable(on interfaceController: CPInterfaceController, detail: String) {
        let item = CPListItem(text: "Rishi unavailable", detailText: detail)
        item.isEnabled = false
        interfaceController.setRootTemplate(
            CPListTemplate(title: "Rishi", sections: [CPListSection(items: [item])]),
            animated: false
        )
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        guard Self.isCurrentInterfaceController(
            connected: connectedInterfaceController.map(ObjectIdentifier.init),
            callback: ObjectIdentifier(interfaceController)
        ) else { return }
        connectedInterfaceController = nil
        connectionID = nil
        let disconnectedSession = session
        session = nil
        Task { @MainActor in
            await disconnectedSession?.disconnect()
        }
    }
}
#endif

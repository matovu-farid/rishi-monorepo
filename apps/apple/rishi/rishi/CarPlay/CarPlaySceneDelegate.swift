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
            let userUUID = (try? Keychain.load(.userId)).flatMap(UUID.init(uuidString:))
            await dependencies.synchronizeCarPlayIdentity(userUUID)
            guard self?.connectionID == connectionID else { return }
            await dependencies.bootstrap()
            guard self?.connectionID == connectionID else { return }
            guard let services = dependencies.services else { return }
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

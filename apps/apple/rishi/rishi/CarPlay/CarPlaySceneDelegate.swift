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
            let userUUID: UUID
            do {
                userUUID = try await RishiAppIntentRuntime.validatedPersistedIdentity()
            } catch let error as RishiAppIntentRuntimeError {
                guard case .signedOut = error,
                      self?.connectionID == connectionID else { return }
                _ = await dependencies.synchronizeCarPlayIdentity(nil)
                Self.showUnavailable(on: interfaceController, detail: error.localizedDescription)
                return
            } catch {
                guard self?.connectionID == connectionID else { return }
                Self.showUnavailable(on: interfaceController, detail: "Please reconnect and try again.")
                return
            }
            guard self?.connectionID == connectionID else { return }
            await dependencies.bootstrap()
            guard self?.connectionID == connectionID else { return }
            guard let services = dependencies.services else {
                guard self?.connectionID == connectionID else { return }
                Self.showUnavailable(on: interfaceController, detail: "Please reconnect and try again.")
                return
            }
            do {
                _ = try await RishiAppIntentRuntime.validateServerIdentity(
                    using: services.workerClient,
                    userID: userUUID
                )
            } catch let error as RishiAppIntentRuntimeError {
                guard case .signedOut = error,
                      self?.connectionID == connectionID else { return }
                _ = await dependencies.synchronizeCarPlayIdentity(nil)
                Self.showUnavailable(on: interfaceController, detail: error.localizedDescription)
                return
            } catch {
                guard self?.connectionID == connectionID else { return }
                Self.showUnavailable(on: interfaceController, detail: "Please reconnect and try again.")
                return
            }
            guard self?.connectionID == connectionID else { return }
            guard await dependencies.synchronizeCarPlayIdentity(userUUID) else {
                guard self?.connectionID == connectionID else { return }
                Self.showUnavailable(on: interfaceController, detail: "Please reconnect and try again.")
                return
            }
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

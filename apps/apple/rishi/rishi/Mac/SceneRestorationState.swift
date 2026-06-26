



















import Foundation
import SwiftUI
import RishiCore
import RishiReader











nonisolated struct RishiSceneState: Equatable, Sendable {
    var selectedTab: MacTab
    var openBookId: BookID?

    
    
    
    
    
    nonisolated static let `default` = RishiSceneState(selectedTab: .library, openBookId: nil)

    
    
    
    
    
    nonisolated static let selectedTabKey  = "rishi.scene.selectedTab"
    nonisolated static let openBookIdKey   = "rishi.scene.openBookId"

    

    
    
    
    
    
    
    
    nonisolated func encodeForStorage() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    
    
    
    
    
    
    
    nonisolated static func decodeFromStorage(_ raw: String) -> RishiSceneState {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RishiSceneState.self, from: data) else {
            return .default
        }
        return decoded
    }

    
    
    
    
    
    
    
    
    
    
    
    
    
    

    
    
    
    
    
    
    
    
    
    
    
    
    

    private enum CodingKeys: String, CodingKey {
        case selectedTab
        case openBookId
    }

    
    
    
    
    nonisolated init(selectedTab: MacTab, openBookId: BookID?) {
        self.selectedTab = selectedTab
        self.openBookId = openBookId
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedTab = try c.decode(MacTab.self, forKey: .selectedTab)
        self.openBookId = try c.decodeIfPresent(BookID.self, forKey: .openBookId)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedTab, forKey: .selectedTab)
        try c.encodeIfPresent(openBookId, forKey: .openBookId)
    }

    nonisolated static func decodeSceneRestoreCells(
        tabRaw: String,
        openBookIdRaw: String
    ) -> (state: RishiSceneState, path: NavigationPath?, route: ReaderRoute?, legacyId: UUID?) {
        let state = Self.decodeFromStorage(tabRaw)
        let path: NavigationPath? = {
            let decoded = NavigationPath.decodeFromStorage(openBookIdRaw)
            return decoded.isEmpty ? nil : decoded
        }()
        let route = ReaderRoute.decodeFromStorage(openBookIdRaw)
        let legacyId = UUID(uuidString: openBookIdRaw)
        return (state, path, route, legacyId)
    }
}





nonisolated extension RishiSceneState: Codable {}











extension ReaderRoute {
    
    nonisolated static func encodeForStorage(_ route: ReaderRoute?) -> String {
        guard let route else { return "" }
        do {
            let data = try JSONEncoder().encode(route)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    
    nonisolated static func decodeFromStorage(_ raw: String) -> ReaderRoute? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReaderRoute.self, from: data)
    }
}











extension NavigationPath {
    
    
    
    
    nonisolated static func encodeForStorage(_ path: NavigationPath) -> String {
        guard let codable = path.codable else { return "" }
        do {
            let data = try JSONEncoder().encode(codable)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    
    
    
    
    nonisolated static func decodeFromStorage(_ raw: String) -> NavigationPath {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return NavigationPath() }
        do {
            let decoded = try JSONDecoder().decode(NavigationPath.CodableRepresentation.self, from: data)
            return NavigationPath(decoded)
        } catch {
            return NavigationPath()
        }
    }
}
